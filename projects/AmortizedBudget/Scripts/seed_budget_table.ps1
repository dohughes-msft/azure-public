<#
.SYNOPSIS
Seeds budget rows into the AmortizedBudget Azure Table.

.DESCRIPTION
Reads budget definitions from a JSON file, validates and normalizes each row, and upserts
entities into the configured budget table in Azure Table Storage. Optional switches can
preview actions, clear existing table entities, and bypass confirmation prompts.

.PARAMETER ConfigFile
Path to the configuration file containing storage account and budget table settings.

.PARAMETER BudgetFile
Path to the JSON file that contains budget rows to seed.

.PARAMETER DryRun
Shows what would be written or deleted without modifying table data.

.PARAMETER ClearAll
Clears all existing entities from the target budget table before seeding.

.PARAMETER Force
Skips confirmation prompts used with destructive operations like ClearAll.

.EXAMPLE
./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json

Seeds budget rows from the input file into the configured budget table.

.EXAMPLE
./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json -DryRun

Shows the rows that would be written without changing table data.

.EXAMPLE
./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json -ClearAll -Force

Clears existing rows and seeds fresh rows without prompts.

.NOTES
Requires Az.Accounts and an authenticated Azure context with table data-plane access
on the target storage account (for example Storage Table Data Contributor).
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = "..\Config\parameters.json",
    [string]$BudgetFile = "..\LocalData\budgets.sample.json",
    [switch]$DryRun,
    [switch]$ClearAll,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        throw "File not found: $Path"
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "File is empty: $Path"
    }

    return $content | ConvertFrom-Json -AsHashtable -Depth 20
}

function Get-ConfigValue {
    param(
        [hashtable]$Map,
        [string]$Key,
        $DefaultValue
    )

    if ($null -ne $Map -and $Map.ContainsKey($Key)) {
        return $Map[$Key]
    }

    return $DefaultValue
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$SecureString)

    if ($null -eq $SecureString) {
        return ""
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-AccessToken {
    param([string]$Resource = "https://storage.azure.com/")

    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        throw "Get-AzAccessToken is not available. Install/import Az.Accounts and authenticate with Connect-AzAccount."
    }

    $azToken = Get-AzAccessToken -ResourceUrl $Resource
    if ($null -eq $azToken) {
        throw "Failed to acquire Azure access token for $Resource."
    }

    if ($azToken.Token -is [Security.SecureString]) {
        return (Convert-SecureStringToPlainText -SecureString $azToken.Token).Trim()
    }

    return ([string]$azToken.Token).Trim()
}

function Invoke-RestWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [AllowNull()]$Body,
        [int]$MaxRetries = 4,
        [double]$BackoffSeconds = 1.5,
        [int]$TimeoutSeconds = 30
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($null -eq $Body) {
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSeconds
            }

            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 30) -ContentType "application/json" -TimeoutSec $TimeoutSeconds
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }

            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -and ($statusCode -notin @(408, 409, 429, 500, 502, 503, 504))) {
                throw
            }

            $delay = [Math]::Min($BackoffSeconds * [Math]::Pow(2, $attempt - 1), 30)
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-TableHeaders {
    param([string]$Token)

    return @{
        Authorization = "Bearer $Token"
        "x-ms-version" = "2019-02-02"
        Accept = "application/json;odata=nometadata"
    }
}

function Initialize-Table {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-Host ("[DryRun] Would ensure table exists: {0}" -f $TableName) -ForegroundColor Yellow
        return
    }

    $headers = Get-TableHeaders -Token $Token
    $uri = "https://$StorageAccount.table.core.windows.net/Tables"

    try {
        Invoke-RestWithRetry -Method "POST" -Uri $uri -Headers $headers -Body @{ TableName = $TableName } -MaxRetries 2 -BackoffSeconds 1 -TimeoutSeconds 15 | Out-Null
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -ne 409) {
            throw
        }
    }
}

function Convert-TableKeyLiteral {
    param([string]$Value)

    return ([string]$Value).Replace("'", "''")
}

function Convert-ToThresholdString {
    param($RawThresholds)

    if ($null -eq $RawThresholds) {
        return ""
    }

    $rawItems = @()
    if ($RawThresholds -is [string]) {
        $rawItems = @([string]$RawThresholds -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    elseif ($RawThresholds -is [System.Collections.IEnumerable] -and $RawThresholds -isnot [string]) {
        $rawItems = @($RawThresholds)
    }
    else {
        $rawItems = @($RawThresholds)
    }

    $parsedValues = @()
    foreach ($item in $rawItems) {
        $parsed = 0.0
        if ([double]::TryParse([string]$item, [ref]$parsed)) {
            $parsedValues += [Math]::Round($parsed, 2)
        }
    }

    return (($parsedValues | Sort-Object -Unique) -join ",")
}

function Convert-ToSeedEntity {
    param($Row)

    $subscriptionId = [string](Get-ConfigValue -Map $Row -Key "subscriptionId" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        $subscriptionId = [string](Get-ConfigValue -Map $Row -Key "PartitionKey" -DefaultValue "")
    }

    $budgetName = [string](Get-ConfigValue -Map $Row -Key "budgetName" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($budgetName)) {
        $budgetName = [string](Get-ConfigValue -Map $Row -Key "RowKey" -DefaultValue "")
    }

    $amountRaw = Get-ConfigValue -Map $Row -Key "budgetAmount" -DefaultValue $null
    if ($null -eq $amountRaw) {
        $amountRaw = Get-ConfigValue -Map $Row -Key "BudgetAmount" -DefaultValue $null
    }

    $amount = 0.0
    $amountIsValid = [double]::TryParse([string]$amountRaw, [ref]$amount)

    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($budgetName) -or -not $amountIsValid -or $amount -le 0) {
        return $null
    }

    $recipientEmail = [string](Get-ConfigValue -Map $Row -Key "recipientEmail" -DefaultValue "")
    $rawThresholds = Get-ConfigValue -Map $Row -Key "actualWarningThresholds" -DefaultValue $null
    if ($null -eq $rawThresholds) {
        $rawThresholds = Get-ConfigValue -Map $Row -Key "warningThresholds" -DefaultValue ""
    }
    $actualWarningThresholds = Convert-ToThresholdString -RawThresholds $rawThresholds

    return [ordered]@{
        PartitionKey = $subscriptionId
        RowKey = $budgetName
        budgetAmount = [Math]::Round($amount, 2)
        actualWarningThresholds = $actualWarningThresholds
        recipientEmail = $recipientEmail
        enabled = Get-ConfigValue -Map $Row -Key "enabled" -DefaultValue $true
    }
}

function Set-BudgetEntity {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [hashtable]$Entity,
        [switch]$DryRun
    )

    $partitionLiteral = Convert-TableKeyLiteral -Value ([string]$Entity.PartitionKey)
    $rowLiteral = Convert-TableKeyLiteral -Value ([string]$Entity.RowKey)
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$partitionLiteral',RowKey='$rowLiteral')"

    if ($DryRun) {
        Write-Host ("[DryRun] Would set entity (insert or replace): PartitionKey='{0}' RowKey='{1}'" -f $Entity.PartitionKey, $Entity.RowKey) -ForegroundColor Yellow
        return
    }

    $headers = Get-TableHeaders -Token $Token
    # No If-Match header: this keeps PUT in insert-or-replace mode.
    Invoke-RestWithRetry -Method "PUT" -Uri $uri -Headers $headers -Body $Entity -MaxRetries 4 -BackoffSeconds 1.5 -TimeoutSeconds 30 | Out-Null
}

function Get-EntityPage {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [AllowNull()][string]$NextPartitionKey,
        [AllowNull()][string]$NextRowKey,
        [int]$TimeoutSeconds = 30,
        [int]$MaxRetries = 4,
        [double]$BackoffSeconds = 1.5
    )

    $headers = Get-TableHeaders -Token $Token
    $baseUri = "https://$StorageAccount.table.core.windows.net/$TableName()"
    $queryParts = @()

    if (-not [string]::IsNullOrWhiteSpace($NextPartitionKey)) {
        $queryParts += "NextPartitionKey=$([System.Uri]::EscapeDataString($NextPartitionKey))"
    }

    if (-not [string]::IsNullOrWhiteSpace($NextRowKey)) {
        $queryParts += "NextRowKey=$([System.Uri]::EscapeDataString($NextRowKey))"
    }

    $uri = if ($queryParts.Count -gt 0) {
        "$baseUri?{0}" -f ($queryParts -join "&")
    }
    else {
        $baseUri
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $responseHeaders = $null
            $result = Invoke-RestMethod -Method "GET" -Uri $uri -Headers $headers -TimeoutSec $TimeoutSeconds -ResponseHeadersVariable responseHeaders

            return @{
                Entities = @($result.value)
                NextPartitionKey = [string]$responseHeaders["x-ms-continuation-NextPartitionKey"]
                NextRowKey = [string]$responseHeaders["x-ms-continuation-NextRowKey"]
            }
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }

            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -and ($statusCode -notin @(408, 409, 429, 500, 502, 503, 504))) {
                throw
            }

            $delay = [Math]::Min($BackoffSeconds * [Math]::Pow(2, $attempt - 1), 30)
            Start-Sleep -Seconds $delay
        }
    }
}

function Clear-AllTableEntities {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [switch]$DryRun
    )

    Write-Warning ("ClearAll enabled. This will delete all existing entities from table '{0}'." -f $TableName)

    if ($DryRun) {
        Write-Host ("[DryRun] Would delete all entities from table: {0}" -f $TableName) -ForegroundColor Yellow
        return
    }

    $deletedCount = 0
    $nextPartitionKey = ""
    $nextRowKey = ""

    do {
        $page = Get-EntityPage -Token $Token -StorageAccount $StorageAccount -TableName $TableName -NextPartitionKey $nextPartitionKey -NextRowKey $nextRowKey

        foreach ($entity in @($page.Entities)) {
            $partitionLiteral = Convert-TableKeyLiteral -Value ([string]$entity.PartitionKey)
            $rowLiteral = Convert-TableKeyLiteral -Value ([string]$entity.RowKey)
            $deleteUri = "https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$partitionLiteral',RowKey='$rowLiteral')"

            $deleteHeaders = Get-TableHeaders -Token $Token
            $deleteHeaders["If-Match"] = "*"

            Invoke-RestWithRetry -Method "DELETE" -Uri $deleteUri -Headers $deleteHeaders -Body $null -MaxRetries 4 -BackoffSeconds 1.5 -TimeoutSeconds 30 | Out-Null
            $deletedCount++
        }

        $nextPartitionKey = [string]$page.NextPartitionKey
        $nextRowKey = [string]$page.NextRowKey
    }
    while (-not [string]::IsNullOrWhiteSpace($nextPartitionKey) -or -not [string]::IsNullOrWhiteSpace($nextRowKey))

    Write-Host ("Deleted rows     : {0}" -f $deletedCount) -ForegroundColor Yellow
}

function Confirm-ClearAll {
    param(
        [string]$TableName,
        [switch]$Force
    )

    if ($Force) {
        return $true
    }

    while ($true) {
        $answer = Read-Host ("Are you sure you want to delete all entries from table '{0}'? (Y/N)" -f $TableName)
        if ($null -eq $answer) {
            continue
        }

        $normalized = $answer.Trim().ToUpperInvariant()
        if ($normalized -eq "Y") {
            return $true
        }

        if ($normalized -eq "N") {
            return $false
        }

        Write-Warning "Please enter Y or N."
    }
}

$config = Import-JsonFile -Path $ConfigFile
$stateConfig = Get-ConfigValue -Map $config -Key "state" -DefaultValue @{}

$storageAccount = [string](Get-ConfigValue -Map $stateConfig -Key "storage_account" -DefaultValue "")
$budgetTableName = [string](Get-ConfigValue -Map $stateConfig -Key "budget_table" -DefaultValue "")

if ([string]::IsNullOrWhiteSpace($storageAccount) -or [string]::IsNullOrWhiteSpace($budgetTableName)) {
    throw "state.storage_account and state.budget_table are required in config."
}

$rawRows = Import-JsonFile -Path $BudgetFile
$rows = @($rawRows)

Write-Host "Seeding budget table" -ForegroundColor Cyan
Write-Host ("Config file     : {0}" -f $ConfigFile)
Write-Host ("Budget file     : {0}" -f $BudgetFile)
Write-Host ("Storage account : {0}" -f $storageAccount)
Write-Host ("Budget table    : {0}" -f $budgetTableName)
Write-Host ("Dry run         : {0}" -f $DryRun.ToString())
Write-Host ("Clear all       : {0}" -f $ClearAll.ToString())
Write-Host ("Force           : {0}" -f $Force.ToString())

$token = ""
if (-not $DryRun) {
    $token = Get-AccessToken -Resource "https://storage.azure.com/"
}

Initialize-Table -Token $token -StorageAccount $storageAccount -TableName $budgetTableName -DryRun:$DryRun

if ($ClearAll) {
    if (-not (Confirm-ClearAll -TableName $budgetTableName -Force:$Force)) {
        Write-Warning "ClearAll canceled by user."
        return
    }

    Clear-AllTableEntities -Token $token -StorageAccount $storageAccount -TableName $budgetTableName -DryRun:$DryRun

    Write-Host ""
    Write-Host "Clear complete" -ForegroundColor Cyan
    return
}

$validCount = 0
$skippedCount = 0

foreach ($row in $rows) {
    if ($row -isnot [hashtable]) {
        $row = $row | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -Depth 20
    }

    $entity = Convert-ToSeedEntity -Row $row
    if ($null -eq $entity) {
        $skippedCount++
        Write-Warning "Skipping invalid row (requires subscriptionId, budgetName, budgetAmount > 0)."
        continue
    }

    Set-BudgetEntity -Token $token -StorageAccount $storageAccount -TableName $budgetTableName -Entity $entity -DryRun:$DryRun
    $validCount++
}

Write-Host ""
Write-Host "Seed complete" -ForegroundColor Cyan
Write-Host ("Rows processed : {0}" -f $rows.Count)
Write-Host ("Rows upserted  : {0}" -f $validCount)
Write-Host ("Rows skipped   : {0}" -f $skippedCount)
