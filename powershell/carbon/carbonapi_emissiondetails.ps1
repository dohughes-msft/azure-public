# Azure Carbon Emissions API Call
# Requires Azure PowerShell module and authenticated session

# Parameters
$apiVersion = "2025-04-01"
$uri = "https://management.azure.com/providers/Microsoft.Carbon/carbonEmissionReports?api-version=$apiVersion"
$subscriptionList = @(
    "69f95403-8f1d-40b6-8ff0-beba8f41adea",
    "b42a8bcf-60dd-4f42-9172-abc08ad2f282"
)

# Possible categories are: Resource, ResourceGroup, ResourceType, Location, Subscription
$category = "Subscription"

$requestBody = @{
    reportType = "ItemDetailsReport"
    subscriptionList = $subscriptionList
    carbonScopeList = @(
        "Scope1",
        "Scope2",
        "Scope3"
    )
    dateRange = @{
        start = "2025-12-01"
        end = "2025-12-31"
    }
    categoryType = "$category"
    sortDirection = "Desc"
    pageSize = 2000
    orderBy = "LatestMonthEmissions"
} | ConvertTo-Json -Depth 10

Write-Output "Requesting report for category: $category"
$response = Invoke-AzRestMethod -Uri $uri -Method Post -Payload $requestBody
($response.Content | ConvertFrom-Json).value | Format-Table
