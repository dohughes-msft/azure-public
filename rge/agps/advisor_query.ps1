<#
.SYNOPSIS
    Query Azure Advisor to get recommendations for a list of subscriptions grouped by workload

.PARAMETER workloadFile
    A JSON file containing a list subscriptions grouped by workload

.PARAMETER outputFile
    Excel file to export the results to. If unspecified, results are displayed in the console

.EXAMPLE
    PS C:\> advisor_query.ps1 -workloadFile ".\subscriptions.json" -outputFile ".\ResourceGraphQueries.xlsx"

.INPUTS
    None

.OUTPUTS
    None

.NOTES
    Requires a modern version of module Az.ResourceGraph that supports skip tokens (0.13.0 confirmed to work)
    https://learn.microsoft.com/en-us/azure/governance/resource-graph/troubleshoot/general#scenario-too-many-subscriptions
    https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/work-with-data#paging-results

    Requires module ImportExcel to export the results to Excel
    https://www.powershellgallery.com/packages/ImportExcel/
    PS1> Install-Module -Name ImportExcel

    The export to Excel may fail if the file exists already and has a sensitivity label applied. To avoid this, set the
    sensitivity label to an unencrypted one.

    Before running the script, connect to the required Azure tenant using:
    C:\> Connect-AzAccount -tenant $tenantId
#>

param (
    [string]$workloadFile = "subscriptions.json",
    [string]$outputFile   = "AdvisorRecommendations.xlsx"
)

# Output to file (true) or console (false)
$fileOutput = $true

$workloads = @()

# Read the content of the workloads file
$jsonContent = Get-Content -Path $workloadFile -Raw

# Convert the JSON content to a PowerShell object
$workloads = $jsonContent | ConvertFrom-Json
$subscriptionIds = $workloads.Subscriptions

# Check there are no duplicate subscription IDs
if ($subscriptionIds.Count -ne $($subscriptionIds | Sort-Object | Get-Unique).Count) {
    Write-Error "Duplicate subscription IDs found in the input file. A subscription ID can only be assigned to one workload."
    return
}

# Output the workloads to Excel
$outputTab = "Workloads"
$workloads | ForEach-Object {
    $workload = $_.Workload
    $_.Subscriptions | ForEach-Object {
        [PSCustomObject]@{
            Workload      = $workload
            Subscription  = $_
        }
    }
} | Export-Excel -WorksheetName $outputTab -TableName $outputTab -Path $outputFile
Write-Output "$($workloads.Subscriptions.Count) results written to tab $outputTab"

$advisorRecs = Get-AzAdvisorRecommendation -SubscriptionId $subscriptionIds `
    | Select-Object `
        @{Name="SubscriptionId"; Expression={$_.Id.Split("/")[2]}}, `
        Category, `
        Impact, `
        ShortDescriptionProblem, `
        ImpactedField, `
        ImpactedValue, `
        LastUpdated

# If an output file is specified, export the table to Excel, otherwise display it
if ($fileOutput) {
    $advisorRecs | Export-Excel -WorksheetName "AzureAdvisor" -TableName "AzureAdvisor" -Path .\$outputFile
    Write-Output "$($advisorRecs.Count) results written to tab AzureAdvisor"
} else {
    $advisorRecs | Format-Table -AutoSize
}
