<#
.SYNOPSIS
    Take a collection of given resource IDs and return the cost history for those resources. For this we use the Microsoft.CostManagement provider
    of the resource group containing the resource.
    Requires Az.CostManagement module 0.4.2 or later.

.PARAMETER ParameterName
    $resourceID[] (mandatory) : The resource IDs of the resources to be examined
    $startDate    (optional)  : The start date of the period to be examined (default is the first day of the month, 6 months ago)
    $endDate      (optional)  : The end date of the period to be examined (default is the last day of the previous month)

.INPUTS
    None

.OUTPUTS
    A table showing the cost history of the given resource over the requested period

.EXAMPLE
    .\get_cost_history.ps1 -resourceId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourcegroups/xxxxxxxx/providers/microsoft.compute/disks/xxxxxxx"
    .\get_cost_history.ps1 -resourceId @("Id1", "Id2", ...)
    .\get_cost_history.ps1 -resourceId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourcegroups/xxxxxxxx/providers/microsoft.compute/disks/xxxxxxx" -startDate "2023-01-01" -endDate "2023-06-30"

.NOTES
    Documentation links:
    https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
    https://learn.microsoft.com/en-us/powershell/module/az.costmanagement/invoke-azcostmanagementquery
#>

param (
    [Parameter(Mandatory=$true)][string[]]$resourceIds,
    [string]$startDate = (Get-Date).AddMonths(-6).ToString("yyyy-MM-01"),               # the first day of the month 6 months ago
    [string]$endDate = (Get-Date).AddDays(-1 * (Get-Date).Day).ToString("yyyy-MM-dd")   # the last day of the previous month
)

# Check if the needed modules are installed
if (-not (Get-Module -ListAvailable -Name Az.CostManagement)) {
    Write-Error "Az.CostManagement module is not installed. Please install it using 'Install-Module -Name Az.CostManagement'."
    exit 1
}

# Timeframe
# Supported types are BillingMonthToDate, Custom, MonthToDate, TheLastBillingMonth, TheLastMonth, WeekToDate
$timeframe = "Custom"

# Granularity
# Supported types are Daily and Monthly so far. Omit just to get the total cost.
$granularity = "Monthly"

# Type
# Supported types are Usage (deprecated), ActualCost, and AmortizedCost
$type = "AmortizedCost"          

# Scope
<# Scope can be:
https://learn.microsoft.com/en-us/powershell/module/az.costmanagement/invoke-azcostmanagementquery?view=azps-10.1.0#-scope

Subscription scope       : /subscriptions/{subscriptionId}
Resource group scope     : /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}
Billing account scope    : /providers/Microsoft.Billing/billingAccounts/{billingAccountId}
Department scope         : /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/departments/{departmentId}
Enrollment account scope : /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/enrollmentAccounts/{enrollmentAccountId}
Management group scope   : /providers/Microsoft.Management/managementGroups/{managementGroupId}
Billing profile scope    : /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/billingProfiles/{billingProfileId}
Invoice section scope    : /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/billingProfiles/{billingProfileId}/invoiceSections/{invoiceSectionId}
Partner scope            : /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/customers/{customerId}

For a customer with a Microsoft Enterprise Agreement or Microsoft Customer Agreement, billing account scope is recommended. #>
#$scope = "/providers/Microsoft.Billing/billingAccounts/12345678"

# For testing purposes the subscription of the first resource ID could be used.
$scope = $resourceIds[0].Split("/")[0..2] -join "/"

# Grouping
<# Dimensions for grouping the output. Valid dimensions for grouping are:

AccountName
BenefitId
BenefitName
BillingAccountId
BillingMonth
BillingPeriod
ChargeType
ConsumedService
CostAllocationRuleName
DepartmentName
EnrollmentAccountName
Frequency
InvoiceNumber
MarkupRuleName
Meter
MeterCategory
MeterId
MeterSubcategory
PartNumber
PricingModel
PublisherType
ReservationId
ReservationName
ResourceGroup
ResourceGroupName
ResourceGuid
ResourceId
ResourceLocation
ResourceType
ServiceName
ServiceTier
SubscriptionId
SubscriptionName
#>
$grouping = @(
    @{
        type = "Dimension"
        name = "ResourceId"
    }
)

# Aggregation
# Supported types are Sum, Average, Minimum, Maximum, Count, and Total.
$aggregation = @{
    PreTaxCost = @{
        type = "Sum"
        name = "PreTaxCost"
    }
}

# Filter
# In this script we use dimension resource ID as a filter
$dimensions = New-AzCostManagementQueryComparisonExpressionObject -Name 'ResourceId' -Value $resourceIds
$filter = New-AzCostManagementQueryFilterObject -Dimensions $dimensions

$queryResult = Invoke-AzCostManagementQuery `
    -Scope $scope `
    -Timeframe $timeframe `
    -Type $type `
    -DatasetFilter $filter `
    -TimePeriodFrom $startDate `
    -TimePeriodTo $endDate `
    -DatasetGrouping $grouping `
    -DatasetAggregation $aggregation
#    -DatasetGranularity $granularity
#    -Debug

#$queryResult | ConvertTo-Json -Depth 10 | Out-File -FilePath "cost_history.json"

# Convert the query result into a table
$table = @()
for ($i = 0; $i -lt $queryResult.Row.Count; $i++) {
    $row = [PSCustomObject]@{}
    for ($j = 0; $j -lt $queryResult.Column.Count; $j++) {
        $row | Add-Member -MemberType NoteProperty -Name $queryResult.Column.Name[$j] -Value $queryResult.Row[$i][$j]
    }
    $table += $row
}

#$table | Export-Csv -Path "cost_history.csv"
$table | Format-Table -AutoSize
