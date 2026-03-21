<#
.SYNOPSIS
    Script to query the Azure Price API for different regions and output the results into separate CSV files
    for each region. This is mainly due to the large dataset returned by the API.
.PARAMETER automationAccount
    If set to true, the script expects to run in an Azure Automation account and will upload the results to a storage account.
.PARAMETER storageAccountName
    The name of the storage account to upload results to. Required when automationAccount is true.
.PARAMETER debugMode
    If set to true, the script will run in debug mode, which is useful for testing
.NOTES
    https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
#>

[CmdletBinding()]
Param
(
  [Parameter (Mandatory=$false)]
  [bool] $automationAccount = $false,

  [Parameter (Mandatory= $false)]
  [string] $storageAccountName,

  [Parameter (Mandatory= $false)]
  [bool] $debugMode = $false
)

function Invoke-WithRetry {
    param(
        [string]$url
    )
    $maxRetries = 5
    $retryDelay = 5
    $retryCount = 0
    $success = $false
    while (-not $success -and $retryCount -lt $maxRetries) {
        try {
            $queryResult = Invoke-RestMethod -Uri $url -Method Get
            $success = $true
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                Write-Verbose "HTTP 429 received. Throttled. Waiting $retryDelay seconds before retrying... (Attempt $($retryCount+1)/$maxRetries)"
                Start-Sleep -Seconds $retryDelay
                $retryDelay = [Math]::Min($retryDelay * 2, 60) # Exponential backoff, max 60s
                $retryCount++
            }
            else {
                Write-Error "API call failed: $($_.Exception.Message)"
                throw $_
            }
        }
    }
    if (-not $success) {
        Write-Error "Failed to retrieve data after $maxRetries attempts."
        Write-Error "URL: $url"
        return $null
    } else {
        return $queryResult
    }
}

$baseUri = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview"
$fileRoot = "pricing_"
$fileExtension = ".json"
$containerName = "pricing"

if ($debugMode) {
    Write-Verbose "Debug mode is ON."
    # Set to false to query only a single region. Useful for debugging.
    $multiRegion = $false

    # Set to false to stop after the first page of results. Useful for debugging.
    $multiPage = $false
} else {
    $multiRegion = $true
    $multiPage = $true
}

# If running in an Azure Automation account, provide the storage account to hold the files.
# Make sure the automation account has a system-assigned managed identity, and that this
# identity has the Storage Blob Data Contributor role on the storage account. Owner is not enough!
if ($automationAccount) {
    if ([string]::IsNullOrWhiteSpace($storageAccountName)) {
        Write-Error "storageAccountName must be specified when running in an automation account."
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

# Regions to query. A separate file will be created for each region.
# The main reason for this is that the API returns a large dataset that will exceed the
# memory available in an Azure Automation account.
if ($multiRegion) {
    Write-Verbose "Fetching all physical regions..."
    $regions = (Get-AzLocation | Where-Object {$_.RegionType -eq "Physical"}).Location | Sort-Object
} else {
    Write-Verbose "Using single region for debugging..."
    $regions = @("westeurope")
}

<#
# If a subset of regions is desired, uncomment and set the desired regions here.
$regions = @(
    "westeurope",
    "northeurope",
    "swedencentral",
    "germanywestcentral"
    )
#>

$regionCount = 0

# Cycle through the regions and query the API
foreach ($region in $regions) {
    $regionCount++
    Write-Verbose "Querying region $regionCount of $($regions.Count): $region"
    $filterString = '$filter=currencyCode eq ''USD'''
    $filterString += " and armRegionName eq '$region'"
    Write-Verbose "Filter string in use is $filterString"
    $uri = "$baseUri&$filterString"
    $table = @()
    $fileName = "$fileRoot$region$fileExtension"

    # Perform the initial call to get the first page
    $queryResult = Invoke-WithRetry -url $uri
    $resultCount = $queryResult.Items.Count

    if ($resultCount -eq 0) {
        Write-Output "Region $regionCount of $($regions.Count): $region : No data found."
        continue
    }
    Write-Verbose "$($queryResult.Items.Count) rows fetched for region $region."
    $table += $queryResult.Items

    # If there are more pages, get them
    if ($multiPage) {
        while ($null -ne $queryResult.NextPageLink) {
            $queryResult = Invoke-WithRetry -url $queryResult.NextPageLink
            if ($null -eq $queryResult) {
                Write-Error "Failed to retrieve data from $($queryResult.NextPageLink). Exiting."
                break
            }

            $resultCount += $queryResult.Items.Count
            $table += $queryResult.Items
            Write-Verbose "$($queryResult.Items.Count) rows fetched for region $region."
            
            if ($null -eq $queryResult.NextPageLink) {
                Write-Output "Region $regionCount of $($regions.Count): $region : $resultCount rows fetched."
            }
        }
    } else {
        Write-Output "Region $regionCount of $($regions.Count): $region : $resultCount rows fetched."
    }

    # Output the results to a file
    if ($automationAccount) {
        Write-Verbose "Uploading results to Azure Storage..."
        $tempFileName = "$env:TEMP\$fileName"
        $table | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempFileName
        try {
            Set-AzStorageBlobContent -Context $storageContext -Container $containerName -File $tempFileName -Blob $fileName -Force
            Write-Output "Results uploaded to Azure Storage: $fileName."
        }
        catch {
            Write-Error "Failed to upload $fileName to Azure Storage. Error: $($_.Exception.Message)"
        }
    } else {
        #$table | ConvertTo-Json -Depth 10 | Out-File -FilePath $fileName
        Write-Verbose "Writing results to local file..."
        $tempFileName = ".\$fileName"
        $table | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempFileName
    }
}

Write-Verbose "All regions processed. Results saved to $fileRoot*.json files."