<#
.SYNOPSIS
    Take a collection of given subscription IDs and return the cost incurred during previous months,
    grouped as needed. For this we use the Microsoft.CostManagement provider of each subscription.
    Requires Az.CostManagement module
    PS1> Install-Module -Name Az.CostManagement

.PARAMETER startDate
    The start date of the period to be examined (default is the first day of the previous month)

.PARAMETER endDate
    The end date of the period to be examined (default is the last day of the previous month)

.PARAMETER workloadFile
    A JSON file containing a list subscriptions grouped by workload (see example below)

.PARAMETER outputFile
    The Excel file to export the results to, otherwise displayed in the console
    Important: The output file must not be encrypted (sensitivity label applied), otherwise the Export-Excel cmdlet will fail

.INPUTS
    None

.OUTPUTS
    None

.EXAMPLE
    .\cost_query.ps1
    .\cost_query.ps1 -startDate "2023-01-01" -endDate "2023-06-30" -workloadFile "subscriptions.json" -outputFile "CostManagementQuery.xlsx"

.NOTES
    Documentation links:
    https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
    https://learn.microsoft.com/en-us/powershell/module/az.costmanagement/invoke-azcostmanagementquery

    Sample JSON input file:

[
    {
        "Workload": "SAP",
        "Subscriptions": [
            "69f95403-8f1d-40b6-8ff0-beba8f41adea",
            "b42a8bcf-60dd-4f42-9172-abc08ad2f282"
        ]
    },
    {
        "Workload": "Citrix",
        "Subscriptions": [
            "3b7e8696-d30a-4b2b-acc3-8e2d46956948",
            "87155661-b471-4573-a86b-1a0d5120b09a"
        ]
    },
    {
        "Workload": "PLM",
        "Subscriptions": [
            "e8605972-0a89-4d50-acce-6a6426c06163"
        ]
    }
]

#>

param (
    [string]$startDate    = (Get-Date).AddMonths(-1).ToString("yyyy-MM-01"),                    # the first day of the previous month
    [string]$endDate      = (Get-Date).AddDays(-1 * (Get-Date).Day).ToString("yyyy-MM-dd"),     # the last day of the previous month
    [string]$workloadFile = "subscriptions.json",
    [string]$outputFile   = "CostManagementQuery.xlsx"
)

# Output to file (true) or console (false)
$fileOutput = $false

# Label used as the tab name and table name in Excel
$label = "VMPricingModels"

# Timeframe
# Supported types are BillingMonthToDate, Custom, MonthToDate, TheLastBillingMonth, TheLastMonth, WeekToDate
$timeframe = "Custom"

# Granularity
# Supported types are Daily and Monthly so far. Omit just to get the total cost.
# Using Daily causes automatic grouping by month, so do not specify BillingMonth in the grouping
$granularity = "Monthly"

# Type
# Supported types are Usage (deprecated), ActualCost, and AmortizedCost
# https://stackoverflow.com/questions/68223909/in-the-azure-consumption-usage-details-api-what-is-the-difference-between-the-m
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
#$scope = "/subscriptions/2228b515-e1c7-4457-83ba-87888ec1efce"

$workloads = @()

# Read the content of the workloads file
$jsonContent = Get-Content -Path $workloadFile -Raw

# Convert the JSON content to a PowerShell object
$workloads = $jsonContent | ConvertFrom-Json
$subscriptionIds = $workloads.Subscriptions

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
#    @{
#        type = "Dimension"
#        name = "BillingMonth"
#    },
    @{
        type = "Dimension"
        name = "SubscriptionId"
    },
    @{
        type = "Dimension"
        name = "MeterCategory"
    },
    @{
        type = "Dimension"
        name = "MeterSubcategory"
    },
    @{
        type = "Dimension"
        name = "Meter"
    },
    @{
        type = "Dimension"
        name = "PricingModel"
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

# Filter on virtual machines only
$dimensions = New-AzCostManagementQueryComparisonExpressionObject -Name 'PricingModel' -Value 'OnDemand' -Operator 'In'
$filter = New-AzCostManagementQueryFilterObject -Dimensions $dimensions

$table = @()

# Loop through subscription IDs
for ($subIndex = 0; $subIndex -lt $subscriptionIds.Count; $subIndex++) {
    $scope = "/subscriptions/$($subscriptionIds[$subIndex])"
    Write-Output "Querying subscription $(${subIndex}+1) of $($subscriptionIds.Count): $($subscriptionIds[$subIndex])"

    $queryResult = Invoke-AzCostManagementQuery `
        -Scope $scope `
        -Timeframe $timeframe `
        -Type $type `
        -TimePeriodFrom $startDate `
        -TimePeriodTo $endDate `
        -DatasetGrouping $grouping `
        -DatasetGranularity $granularity `
        -DatasetAggregation $aggregation `
        -DatasetFilter $filter

        # Convert the query result into a table
    for ($i = 0; $i -lt $queryResult.Row.Count; $i++) {
        $row = [PSCustomObject]@{}
        for ($j = 0; $j -lt $queryResult.Column.Count; $j++) {
            $row | Add-Member -MemberType NoteProperty -Name $queryResult.Column.Name[$j] -Value $queryResult.Row[$i][$j]
        }
        $table += $row
    }
    # For testing - limit to one subscription
    #$subIndex = $subscriptionIds.Count
}

# If an output file is specified, export the table to Excel, otherwise display it
if ($fileOutput) {
    #$table | Export-Csv -Path .\$outputFile #-NoTypeInformation
    $table | Export-Excel -WorksheetName $label -TableName $label -Path .\$outputFile
    Write-Output "$($table.Count) rows written to $outputFile"
} else {
    $table | Format-Table -AutoSize
}
