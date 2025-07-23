<#
.SYNOPSIS
    This script retrieves the Azure Price Sheet for a specific billing account and period. Works only for MCA accounts.
.PARAMETER billingAccountName
    The name of the billing account for which the price sheet is requested.
.PARAMETER billingProfileName
    The name of the billing profile for which the price sheet is requested.
.EXAMPLE
    .\get_azure_customer_pricing_mca.ps1 -billingAccountId "8611537" -billingPeriod "202507"
.NOTES
    https://learn.microsoft.com/en-us/rest/api/cost-management/price-sheet/download-by-billing-profile
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $billingAccountName,

    [Parameter(Mandatory = $true)]
    [string] $billingProfileName
)

$apiVersion = "2025-03-01"

$uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$billingAccountName/billingProfiles/$billingProfileName/providers/Microsoft.CostManagement/pricesheets/default/download?api-version=$apiVersion"

$initiateExportResult = Invoke-AzRestMethod -Uri $uri -Method Post

if ($initiateExportResult.StatusCode -ne 202) {
    Write-Error "Failed to initiate export. Status code: $($initiateExportResult.StatusCode)"
    exit 1
} else {
    Write-Output "Export initiated successfully for billing account '$billingAccountName' and profile '$billingProfileName'."
}

$operationPath = "https://management.azure.com" + $initiateExportResult.Headers.Location.AbsolutePath + "?api-version=$apiVersion"
$getExportStatus = Invoke-AzRestMethod -uri $operationPath -Method GET

while ($getExportStatus.StatusCode -eq 202) {
    Start-Sleep -Seconds 10
    $i = $i + 10
    $getExportStatus = Invoke-AzRestMethod -uri $operationPath -Method GET
    Write-Output "Waiting for the cost report to be prepared. Elapsed time: $i seconds"
}

if ($getExportStatus.StatusCode -ne 200) {
    Write-Error "Failed to retrieve the export status. Status code: $($getExportStatus.StatusCode)"
    exit 1
}

$exportLocation = ($getExportStatus.Content | ConvertFrom-Json).properties.downloadUrl
$fileName = ($exportLocation.Split("/")[-1]).Split("?")[0]
Invoke-RestMethod -Uri $exportLocation -Method Get -OutFile $fileName -StatusCodeVariable 'statusCode'

if ($statusCode -ne 200) {
    Write-Error "Failed to download the price sheet. Status code: $statusCode"
    exit 1
} else {
    Write-Output "Price sheet downloaded successfully as '$fileName'."
}
