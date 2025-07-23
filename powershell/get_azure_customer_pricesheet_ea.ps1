<#
.SYNOPSIS
    This script retrieves the Azure Price Sheet for a specific billing account and period. Works only for EA accounts.
.PARAMETER billingAccountId
    The ID of the billing account for which the price sheet is requested.
.PARAMETER billingPeriod
    The billing period for which the price sheet is requested. Defaults to the current month if not specified.
.EXAMPLE
    .\get_azure_customer_pricing_ea.ps1 -billingAccountId "8611537" -billingPeriod "202507"
.NOTES
    https://learn.microsoft.com/en-us/rest/api/cost-management/price-sheet/download-by-billing-account
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $billingAccountId,

    [Parameter(Mandatory = $false)]
    [string] $billingPeriod = (Get-Date).ToString("yyyyMM")
)

$apiVersion = "2025-03-01"

$uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$billingAccountId/billingPeriods/$billingPeriod/providers/Microsoft.CostManagement/pricesheets/default/download?api-version=$apiVersion"

$initiateExportResult = Invoke-AzRestMethod -Uri $uri -Method Post

if ($initiateExportResult.StatusCode -ne 202) {
    Write-Error "Failed to initiate export. Status code: $($initiateExportResult.StatusCode)"
    exit 1
} else {
    Write-Output "Export initiated successfully for billing account '$billingAccountId' and period '$billingPeriod'."
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
