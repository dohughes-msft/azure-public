# Azure Carbon Emissions API Call
# Requires Azure PowerShell module and authenticated session

# Parameters
$apiVersion = "2025-04-01"
$uri = "https://management.azure.com/providers/Microsoft.Carbon/queryCarbonEmissionDataAvailableDateRange?api-version=$apiVersion"

$response = Invoke-AzRestMethod -Uri $uri -Method Post
$response.Content | ConvertFrom-Json
