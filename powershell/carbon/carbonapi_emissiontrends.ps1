# Azure Carbon Emissions API Call
# Requires Azure PowerShell module and authenticated session

# Parameters
$apiVersion = "2025-04-01"
$uri = "https://management.azure.com/providers/Microsoft.Carbon/carbonEmissionReports?api-version=$apiVersion"
$subscriptionList = @(
    "69f95403-8f1d-40b6-8ff0-beba8f41adea",
    "b42a8bcf-60dd-4f42-9172-abc08ad2f282"
)

$scopes = @("Scope1", "Scope2", "Scope3")
$table = @()
$allData = @()

foreach ($scope in $scopes) {
    # Request body
    $requestBody = @{
        reportType = "MonthlySummaryReport"
        subscriptionList = $subscriptionList
        carbonScopeList = @(
            "$scope"
        )
        dateRange = @{
            start = "2025-01-01"
            end = "2025-12-31"
        }
    } | ConvertTo-Json -Depth 10
    
    Write-Output "Requesting report for scope: $scope"
    $response = Invoke-AzRestMethod -Uri $uri -Method Post -Payload $requestBody

    # Collect data with scope information for later pivoting
    ($response.Content | ConvertFrom-Json).value | ForEach-Object {
        $allData += [PSCustomObject]@{
            Month = $_.date
            Scope = $scope
            CarbonIntensity = $_.carbonIntensity
            LatestMonthEmissions = $_.latestMonthEmissions
        }
    }
}

# Pivot the data: group by month and create columns for each scope
$table = $allData | Group-Object Month | ForEach-Object {
    $monthData = $_.Group
    
    $ci1 = ($monthData | Where-Object {$_.Scope -eq "Scope1"} | Measure-Object -Property CarbonIntensity -Sum).Sum
    $ci2 = ($monthData | Where-Object {$_.Scope -eq "Scope2"} | Measure-Object -Property CarbonIntensity -Sum).Sum
    $ci3 = ($monthData | Where-Object {$_.Scope -eq "Scope3"} | Measure-Object -Property CarbonIntensity -Sum).Sum
    $citotal = ($ci1 + $ci2 + $ci3) * 1000

    $lme1 = ($monthData | Where-Object {$_.Scope -eq "Scope1"} | Measure-Object -Property LatestMonthEmissions -Sum).Sum
    $lme2 = ($monthData | Where-Object {$_.Scope -eq "Scope2"} | Measure-Object -Property LatestMonthEmissions -Sum).Sum
    $lme3 = ($monthData | Where-Object {$_.Scope -eq "Scope3"} | Measure-Object -Property LatestMonthEmissions -Sum).Sum
    $lmetotal = $lme1 + $lme2 + $lme3
    
    [PSCustomObject]@{
        Month = $_.Name
        TotalEmissions = $lmetotal
        Scope1 = $lme1
        Scope2 = $lme2
        Scope3 = $lme3
        CarbonIntensity = $citotal
    }
}

$table | Format-Table -AutoSize
