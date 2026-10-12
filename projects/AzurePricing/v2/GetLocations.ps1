<#
.SYNOPSIS
    Outputs a JSON file containing an array of Azure physical region locations with their display names.
.PARAMETER automationAccount
    If set to true, the script expects to run in an Azure Automation account and will upload the results to a storage account.
    If false, the results will be saved to a local file. Default is false.
.PARAMETER storageAccountName
    The name of the storage account to upload results to. Required when automationAccount is true.
.PARAMETER containerName
    The name of the blob container to upload results to. Required when automationAccount is true.
.NOTES
    Requires the Az.Accounts and Az.Resources modules. Az.Storage is also required when running in an automation account.
#>

[CmdletBinding()]
Param
(
  [Parameter (Mandatory=$false)]
  [bool] $automationAccount = $false,

  [Parameter (Mandatory=$false)]
  [string] $storageAccountName = "azpricingstg2",

  [Parameter (Mandatory=$false)]
  [string] $containerName = "locations"
)

$fileName = "locations.json"

# Check for required Az modules
$requiredModules = @("Az.Accounts", "Az.Resources")
if ($automationAccount) {
    $requiredModules += "Az.Storage"
}
$missingModules = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missingModules) {
    Write-Error "Missing required PowerShell modules: $($missingModules -join ', '). Install them with: Install-Module $($missingModules -join ', ')"
    exit
}

# If running in an Azure Automation account, check parameters and create the storage context.
if ($automationAccount) {
    if ([string]::IsNullOrWhiteSpace($storageAccountName) -or [string]::IsNullOrWhiteSpace($containerName)) {
        Write-Error "storageAccountName and containerName must be specified when automationAccount is true."
        exit
    }
    try {
        Connect-AzAccount -Identity -ErrorAction Stop
    } catch {
        Write-Output "Failed to authenticate using managed identity. Ensure the automation account has a system-assigned managed identity."
        exit
    }
    try {
        $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
    } catch {
        Write-Output "Failed to connect to Azure Storage. Ensure the automation account has a system-assigned managed identity with the Storage Blob Data Contributor role."
        exit
    }
}

$locations = Get-AzLocation | Where-Object { $_.RegionType -eq "Physical" } |
    Select-Object Location, DisplayName |
    Sort-Object Location

if ($automationAccount) {
    Write-Verbose "Uploading results to Azure Storage..."
    $tempFileName = "$env:TEMP\$fileName"
    $locations | ConvertTo-Json -Depth 5 | Out-File -FilePath $tempFileName
    try {
        Set-AzStorageBlobContent -Context $storageContext -Container $containerName -File $tempFileName -Blob $fileName -Force
        Write-Output "$($locations.Count) locations uploaded to Azure Storage: $fileName."
    }
    catch {
        Write-Error "Failed to upload $fileName to Azure Storage. Error: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path $tempFileName) { Remove-Item $tempFileName -Force }
    }
} else {
    $locations | ConvertTo-Json -Depth 5 | Out-File -FilePath ".\$fileName"
    Write-Output "$($locations.Count) locations written to $fileName"
}
