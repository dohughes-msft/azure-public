# Azure Carbon Emissions API Call
# Requires Azure PowerShell module and authenticated session

# This script invoked the Top Items Monthly Summary Report for

# Parameters
$apiVersion = "2025-04-01"
$uri = "https://management.azure.com/providers/Microsoft.Carbon/carbonEmissionReports?api-version=$apiVersion"
$subscriptionList = @(
    "69f95403-8f1d-40b6-8ff0-beba8f41adea",
    "b42a8bcf-60dd-4f42-9172-abc08ad2f282"
)

# Possible categories are: Resource, ResourceGroup, ResourceType, Location, Subscription
$category = "Subscription"

# Request body
$requestBody = @{
    reportType = "TopItemsMonthlySummaryReport"
    subscriptionList = $subscriptionList
    carbonScopeList = @(
        "Scope1",
        "Scope2",
        "Scope3"
    )
    dateRange = @{
        start = "2025-01-01"
        end = "2025-12-31"
    }
    categoryType = "$category"
    topItems = 6
} | ConvertTo-Json -Depth 10

$response = Invoke-AzRestMethod -Uri $uri -Method Post -Payload $requestBody
($response.Content | ConvertFrom-Json).value | Format-Table
