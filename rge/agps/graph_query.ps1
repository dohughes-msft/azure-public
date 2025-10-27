<#
.SYNOPSIS
    Run a series of resource graph queries and place the outputs in Excel tabs

.PARAMETER assessmentTypes
    Assessment type(s) to filter the queries by

.PARAMETER workloadFile
    A JSON file containing a list subscriptions grouped by workload
    The file must be in JSON format and contain the following properties:
        - Workload: The name of the workload
        - Subscriptions: A list of subscription IDs to query

.PARAMETER queryDir
    Directory containing the JSON files with the queries to run. The files must be in JSON format and contain
    the following properties:
        - label: The name of the query
        - table: The name of the table to query
        - queryBody: The body of the query
        - usecases: A list of use cases for the query

.PARAMETER outputFile
    Excel file to export the results to. If unspecified, results are displayed in the console

.EXAMPLE
    PS C:\> graph_query.ps1 -assessmentTypes WARA,WAPA -workloadFile ".\subscriptions.json" -outputFile ".\ResourceGraphQueries.xlsx"

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
    [Parameter(Mandatory = $true)][string[]]$assessmentTypes,
    [string]$workloadFile = "subscriptions.json",
    [string]$queryDir     = "kql-json",
    [string]$outputFile   = "ResourceGraphQueries.xlsx"
)

function runQuery ($id, $query, $label) {
    # Resource Graph queries are limited to 1000 results at a time and can look at 1000 subscriptions at a time
    # For both subscriptions and results therefore we need to process them in batches

    # Create a counter, set the batch size for subscriptions, and prepare a variable for the results
    $counter = [PSCustomObject] @{ Value = 0 }
    $batchSize = 1000
    $resultSet = @()

    # Group the subscriptions into batches
    $subscriptionsBatch = $subscriptionIds | Group-Object -Property { [math]::Floor($counter.Value++ / $batchSize) }

    # Run the query(ies) for each batch
    foreach ($batch in $subscriptionsBatch) {
        # Run the first query
        $response = Search-AzGraph -Query $query -Subscription $batch.Group -First 1000
        
        # If the result set is empty, add the query to the no result queries
        if ($response.Count -eq 0) {
            $noResultQuery = [PSCustomObject]@{
                ID       = $id
                Query    = $label
            }
            $script:noResultQueries += $noResultQuery
            return
        }
        
        $resultSet += $response

        # If a skip token is returned, there are more results to fetch
        while ($null -ne $response.SkipToken) {
            $response = Search-AzGraph -Query $query -Subscription $batch.Group -First 1000 -SkipToken $response.SkipToken
            $resultSet += $response
        }
    }

    # View the completed results of the query on all subscriptions
    #$resultSet.id | Out-File -FilePath $outputFile -Width 1000

    $resultSet | Export-Excel -WorksheetName $label -TableName $label -Path $outputFile
    # $resultSet | Export-Csv -Path $outputFile -UseQuotes Never
    Write-Output "$($resultSet.Count) results written to tab $label"
}

# Initialise the variables
$workloads         = @()                          # Workloads loaded from the workload file
$queries           = @()                          # Queries loaded from the query files
$skippedQueries    = @()                          # Skipped queries that are not applicable to the assessment type
$noResultQueries   = @()                          # Queries that returned no results
$schemaDir         = "schema"                     # Directory containing the schema files
$workloadSchema    = "$schemaDir\workload.json"   # Schema file for the workloads
$querySchema       = "$schemaDir\query.json"      # Schema file for the queries

# Read the input files
$workloadFileContent = Get-Content -Path $workloadFile -Raw

if ($workloadFileContent | Test-Json -SchemaFile $workloadSchema -ErrorAction SilentlyContinue) {
    $workloads = ConvertFrom-Json $workloadFileContent -ErrorAction Stop
} else {
    Write-Host "Workload file '$workloadFile' does not contain valid JSON."
    return
}

$subscriptionIds = $workloads.Subscriptions

# Check there are no duplicate subscription IDs
if ($subscriptionIds.Count -ne $($subscriptionIds | Sort-Object | Get-Unique).Count) {
    Write-Error "Duplicate subscription IDs found in the input file. A subscription ID can only be assigned to one workload."
    return
}

# Prepare the where statement that will be applied to all queries
$wheresubkql = "| where subscriptionId in ('$($subscriptionIds -join ''',''')')"

# Load the queries from the JSON files
$queryFiles = Get-ChildItem -Path $queryDir -Filter *.json | Select-Object -ExpandProperty Name | Sort-Object

foreach ($queryFile in $queryFiles) {
    $jsonContent = Get-Content -Path "$queryDir\$queryFile" -Raw
    if ($jsonContent | Test-Json -SchemaFile $querySchema -ErrorAction SilentlyContinue) {
        $queries += $jsonContent | ConvertFrom-Json
    } else {
        Write-Host "Query file '$queryFile' does not contain valid JSON."
        return
    }
}

# Create the first tab with the workload and subscriptions
$label = "Workloads"
$workloads | ForEach-Object {
    $workload = $_.Workload
    $_.Subscriptions | ForEach-Object {
        [PSCustomObject]@{
            Workload      = $workload
            Subscription  = $_
        }
    }
} | Export-Excel -WorksheetName $label -TableName $label -Path $outputFile
Write-Output "$($workloads.Subscriptions.Count) results written to tab $label"

# Run each query, checking first whether it is applicable to the assessment type

for ($i = 0; $i -lt $queries.Count; $i++) {
    $executeQuery = $false

    # Check if this query is applicable to the assessment type
    foreach ($assessmentType in $assessmentTypes) {
        if ($queries[$i].usecases -contains $assessmentType) {
            $executeQuery = $true
        }
    }

    if ($executeQuery) {
        $id    = $queries[$i].id
        $label = $queries[$i].label
        $query = $queries[$i].table + " " + $wheresubkql + " " + $queries[$i].queryBody
        runQuery $id $query $label
    } else {
        $skippedQuery = [PSCustomObject]@{
            ID       = $queries[$i].id
            Query    = $queries[$i].label
            Usecases = $queries[$i].usecases -join ", "
        }
        $skippedQueries += $skippedQuery
    }
}

# Output the skipped queries to Excel
$label = "Skipped"
$skippedQueries | Export-Excel -WorksheetName $label -TableName $label -Path $outputFile
Write-Output "$($skippedQueries.Count) results written to tab $label"

# Output the no result queries to Excel
$label = "NoResult"
$noResultQueries | Export-Excel -WorksheetName $label -TableName $label -Path $outputFile
Write-Output "$($noResultQueries.Count) results written to tab $label"
