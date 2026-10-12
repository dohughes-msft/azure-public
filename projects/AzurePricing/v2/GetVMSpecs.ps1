<#
.SYNOPSIS
    Outputs Azure VM size metadata as JSON.

.DESCRIPTION
    Queries Microsoft.Compute SKU metadata (not existing VM resources) and
    returns one row per VM size with technical name, cores, and RAM in GB.
    For constrained SKUs (for example E16-8s_v3), Cores uses vCPUsAvailable
    when present.

.PARAMETER automationAccount
    If true, authenticates with managed identity and uploads output to blob storage.
    If false, writes output locally. Default is false.

.PARAMETER storageAccountName
    Storage account name used for upload in automation account mode.

.PARAMETER containerName
    Blob container name used for upload in automation account mode.

.PARAMETER compressFiles
    If true, output is gzip compressed. Default is true.

.PARAMETER includeRestricted
    Include sizes currently restricted in the subscription context.

.NOTES
    Requires Az.Accounts and Az.Compute. Az.Storage is also required when
    automationAccount is true.
#>

[CmdletBinding()]
Param
(
  [Parameter (Mandatory=$false)]
  [bool] $automationAccount = $false,

  [Parameter (Mandatory=$false)]
  [string] $storageAccountName = "azpricingstg2",

  [Parameter (Mandatory=$false)]
  [string] $containerName = "vmspecs",

  [Parameter (Mandatory=$false)]
  [bool] $compressFiles = $true,

  [Parameter (Mandatory=$false)]
  [bool] $includeRestricted = $false
)

function Get-CapabilityValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Sku,

        [Parameter(Mandatory = $true)]
        [string]$CapabilityName
    )

    $match = $Sku.Capabilities | Where-Object { $_.Name -eq $CapabilityName } | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Value
}

function Compress-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $inputStream = [System.IO.File]::OpenRead($InputFile)
    $outputStream = [System.IO.File]::Create($OutputFile)
    $gzipStream = [System.IO.Compression.GZipStream]::new($outputStream, [System.IO.Compression.CompressionMode]::Compress)

    try {
        $inputStream.CopyTo($gzipStream)
    }
    finally {
        $gzipStream.Dispose()
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
}

# Check for required Az modules
$requiredModules = @("Az.Accounts", "Az.Compute")
if ($automationAccount) {
    $requiredModules += "Az.Storage"
}
$missingModules = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missingModules) {
    Write-Error "Missing required PowerShell modules: $($missingModules -join ', '). Install them with: Install-Module $($missingModules -join ', ')"
    exit
}

if ($automationAccount) {
    if ([string]::IsNullOrWhiteSpace($storageAccountName) -or [string]::IsNullOrWhiteSpace($containerName)) {
        Write-Error "storageAccountName and containerName must be specified when automationAccount is true."
        exit
    }

    try {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Output "Failed to authenticate using managed identity. Ensure the automation account has a system-assigned managed identity."
        exit
    }

    try {
        $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
    }
    catch {
        Write-Output "Failed to connect to Azure Storage. Ensure the automation account has a system-assigned managed identity with the Storage Blob Data Contributor role."
        exit
    }
}

$locations = Get-AzLocation | Select-Object -ExpandProperty Location -Unique
if (-not $locations) {
    Write-Error "No Azure locations were returned for the current context."
    exit
}

$resultsByName = @{}

foreach ($location in $locations) {
    Write-Verbose "Querying VM SKUs for location '$location'..."

    try {
        $locationSkus = Get-AzComputeResourceSku -Location $location -ErrorAction Stop |
            Where-Object { $_.ResourceType -eq "virtualMachines" }
    }
    catch {
        Write-Warning "Skipping location '$location' due to query failure: $($_.Exception.Message)"
        continue
    }

    if (-not $includeRestricted) {
        $locationSkus = $locationSkus | Where-Object { -not $_.Restrictions -or $_.Restrictions.Count -eq 0 }
    }

    foreach ($sku in $locationSkus) {
        if ($resultsByName.ContainsKey($sku.Name)) {
            continue
        }

        $totalCores = Get-CapabilityValue -Sku $sku -CapabilityName "vCPUs"
        $availableCores = Get-CapabilityValue -Sku $sku -CapabilityName "vCPUsAvailable"

        $cores = if ($availableCores) {
            [int]$availableCores
        }
        elseif ($totalCores) {
            [int]$totalCores
        }
        else {
            $null
        }

        $ramGb = Get-CapabilityValue -Sku $sku -CapabilityName "MemoryGB"

        $resultsByName[$sku.Name] = [PSCustomObject]@{
            TechnicalName  = $sku.Name
            Cores          = $cores
            TotalCores     = if ($totalCores) { [int]$totalCores } else { $null }
            AvailableCores = if ($availableCores) { [int]$availableCores } else { $null }
            RAMGB          = if ($ramGb) { [double]$ramGb } else { $null }
            Family         = $sku.Family
        }
    }
}

$results = $resultsByName.Values | Sort-Object TechnicalName

$fileName = "vmspecs.json"

if ($automationAccount) {
    Write-Verbose "Uploading VM specs to Azure Storage..."
    $tempFileName = Join-Path -Path $env:TEMP -ChildPath $fileName
    $results | ConvertTo-Json -Depth 5 | Out-File -FilePath $tempFileName

    if ($compressFiles) {
        $tempGzFileName = "$tempFileName.gz"
        $blobName = "$fileName.gz"

        try {
            Compress-File -InputFile $tempFileName -OutputFile $tempGzFileName
            Set-AzStorageBlobContent -Context $storageContext -Container $containerName -File $tempGzFileName -Blob $blobName -Force -Properties @{ ContentType = "application/gzip" } | Out-Null
            Write-Output "$($results.Count) VM specs uploaded to Azure Storage: $blobName"
        }
        catch {
            Write-Error "Failed to upload $blobName to Azure Storage. Error: $($_.Exception.Message)"
        }
        finally {
            if (Test-Path $tempFileName) { Remove-Item $tempFileName -Force }
            if (Test-Path $tempGzFileName) { Remove-Item $tempGzFileName -Force }
        }
    }
    else {
        try {
            Set-AzStorageBlobContent -Context $storageContext -Container $containerName -File $tempFileName -Blob $fileName -Force -Properties @{ ContentType = "application/json" } | Out-Null
            Write-Output "$($results.Count) VM specs uploaded to Azure Storage: $fileName"
        }
        catch {
            Write-Error "Failed to upload $fileName to Azure Storage. Error: $($_.Exception.Message)"
        }
        finally {
            if (Test-Path $tempFileName) { Remove-Item $tempFileName -Force }
        }
    }
}
else {
    if ($compressFiles) {
        $tempFileName = Join-Path -Path $PSScriptRoot -ChildPath $fileName
        $gzFileName = "$tempFileName.gz"

        $results | ConvertTo-Json -Depth 5 | Out-File -FilePath $tempFileName
        Compress-File -InputFile $tempFileName -OutputFile $gzFileName
        if (Test-Path $tempFileName) { Remove-Item $tempFileName -Force }
        Write-Output "$($results.Count) VM specs written to $gzFileName"
    }
    else {
        $outputFileName = Join-Path -Path $PSScriptRoot -ChildPath $fileName
        $results | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputFileName
        Write-Output "$($results.Count) VM specs written to $outputFileName"
    }
}
