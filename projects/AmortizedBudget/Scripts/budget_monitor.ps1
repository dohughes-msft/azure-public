<#
.SYNOPSIS
Evaluates amortized spend against budget rules and records alert state.

.DESCRIPTION
Runs the AmortizedBudget monitor by loading spend data and budget data from either local
files or Azure services, evaluating utilization thresholds, and writing alert dedupe state.
In AzureAutomation mode the script uses Cost API and Azure Table only, and emits output
to standard output.

.PARAMETER ExecutionMode
Execution context. Use Local for local/testing workflows or AzureAutomation for runbook
execution with Azure-only data sources.

.PARAMETER ConfigFile
Path to the configuration file used for local runs when CostAPI and/or AzureTable data
sources are selected.

.PARAMETER LogFile
Optional log file path for local runs. In AzureAutomation mode, output is stdout-only.

.PARAMETER SpendData
Spend input source: File (Local execution mode only) or CostAPI.

.PARAMETER BudgetData
Budget input source: File (Local execution mode only) or AzureTable.

.PARAMETER StateData
Memory: No persistent state between runs
AzureTable: Persist state in Azure Table for alert deduplication between runs.

.PARAMETER SpendFile
Path to spend input JSON when SpendData is File.

.PARAMETER BudgetFile
Path to budget input JSON when BudgetData is File.

.PARAMETER BillingAccountId
Billing account ID used for Cost Management queries when SpendData is CostAPI.

.PARAMETER BillingProfileId
Billing profile ID used for Cost Management queries when SpendData is CostAPI.

.PARAMETER StorageAccount
Storage account name containing budget and alert-state tables when BudgetData is AzureTable.

.PARAMETER BudgetTable
Azure Table name containing budget definitions.

.PARAMETER AlertStateTable
Azure Table name used to persist alert dedupe state.

.PARAMETER PartitionPrefix
Partition key prefix used for alert-state rows.

.EXAMPLE
./Scripts/budget_monitor.ps1 -ExecutionMode Local -SpendData File -BudgetData File -SpendFile ./LocalData/spend.sample.json -BudgetFile ./LocalData/budgets.sample.json

Runs a local file-based evaluation.

.EXAMPLE
./Scripts/budget_monitor.ps1 -ExecutionMode AzureAutomation -SpendData CostAPI -BudgetData AzureTable -BillingAccountId <billing-account-id> -BillingProfileId <billing-profile-id> -StorageAccount <storage-account> -BudgetTable <budget-table> -AlertStateTable <alert-state-table>

Runs the monitor using live Azure data sources for Automation.

.NOTES
Requires Az.Accounts and an authenticated context. For table operations, the running
identity needs data-plane permissions such as Storage Table Data Contributor.
#>

[CmdletBinding()]
param(
    [ValidateSet("Local", "AzureAutomation")]
    [string]$ExecutionMode = "Local",
    [string]$ConfigFile = "..\Config\parameters.json",
    [string]$LogFile = "..\Logs\amortized_budget_monitor.log",
    [ValidateSet("File", "CostAPI")]
    [string]$SpendData = "File",
    [ValidateSet("File", "AzureTable")]
    [string]$BudgetData = "File",
    [ValidateSet("Memory", "AzureTable")]
    [string]$StateData = "Memory",
    [string]$SpendFile = "..\LocalData\spend.sample.json",
    [string]$BudgetFile = "..\LocalData\budgets.sample.json",
    [string]$BillingAccountId = "",
    [string]$BillingProfileId = "",
    [string]$StorageAccount = "",
    [string]$BudgetTable = "AmortizedBudgetConfig",
    [string]$AlertStateTable = "AmortizedBudgetAlertState",
    [string]$PartitionPrefix = "amortized-budget"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return @{}
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return @{}
    }

    return $content | ConvertFrom-Json -AsHashtable -Depth 20
}

function Resolve-RelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $basePath = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $basePath -ChildPath $Path))
}

function Resolve-SchemaPath {
    param([string]$ConfigFile)

    $configDir = Split-Path -Path $ConfigFile -Parent
    $defaultSchemaPath = Join-Path -Path $configDir -ChildPath "parameters.schema.json"

    $configObj = Import-JsonFile -Path $ConfigFile
    if ($configObj.ContainsKey("`$schema")) {
        $declaredSchema = [string]$configObj["`$schema"]
        if (-not [string]::IsNullOrWhiteSpace($declaredSchema)) {
            if ([System.IO.Path]::IsPathRooted($declaredSchema)) {
                return $declaredSchema
            }

            return Join-Path -Path $configDir -ChildPath $declaredSchema
        }
    }

    return $defaultSchemaPath
}

function Test-ConfigSchema {
    param([string]$ConfigFile)

    if (-not (Test-Path -Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }

    $raw = Get-Content -Path $ConfigFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Configuration file is empty: $ConfigFile"
    }

    $schemaPath = Resolve-SchemaPath -ConfigFile $ConfigFile
    if (-not (Test-Path -Path $schemaPath)) {
        throw "Configuration schema file not found: $schemaPath"
    }

    try {
        $isValid = $raw | Test-Json -SchemaFile $schemaPath
    }
    catch {
        throw "Configuration schema validation failed: $($_.Exception.Message)"
    }

    if (-not $isValid) {
        throw "Configuration does not conform to schema: $schemaPath"
    }
}

function Import-Config {
    param([string]$ConfigFile)

    $fileConfig = Import-JsonFile -Path $ConfigFile

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

    $stateConfig = @{}
    if ($fileConfig.ContainsKey("state")) {
        $stateConfig = $fileConfig.state
    }

    return [PSCustomObject]@{
        billing_account_id = [string](Get-ConfigValue -Map $fileConfig -Key "billing_account_id" -DefaultValue "")
        billing_profile_id = [string](Get-ConfigValue -Map $fileConfig -Key "billing_profile_id" -DefaultValue "")
        state = [PSCustomObject]@{
            storage_account = [string](Get-ConfigValue -Map $stateConfig -Key "storage_account" -DefaultValue "")
            budget_table = [string](Get-ConfigValue -Map $stateConfig -Key "budget_table" -DefaultValue "")
            alert_state_table = [string](Get-ConfigValue -Map $stateConfig -Key "alert_state_table" -DefaultValue "")
            partition_prefix = [string](Get-ConfigValue -Map $stateConfig -Key "partition_prefix" -DefaultValue "amortized-budget")
        }
    }
}

function Import-SpendFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Spend file path is required."
    }

    if (-not (Test-Path -Path $Path)) {
        throw "Spend file not found: $Path"
    }

    Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
}

function Import-BudgetFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Budget file path is required."
    }

    if (-not (Test-Path -Path $Path)) {
        throw "Budget file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 20
    return @($raw)
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
    param(
        [string]$Resource = "https://management.azure.com/"
    )

    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        throw "Get-AzAccessToken is not available. Install/import Az.Accounts and authenticate with Connect-AzAccount."
    }

    $token = ""
    try {
        $azToken = Get-AzAccessToken -ResourceUrl $Resource
        if ($null -ne $azToken) {
            if ($azToken.Token -is [Security.SecureString]) {
                $token = Convert-SecureStringToPlainText -SecureString $azToken.Token
            }
            else {
                $token = [string]$azToken.Token
            }
        }
    }
    catch {
        throw "Failed to acquire Azure access token via Get-AzAccessToken. Authenticate with Connect-AzAccount and retry. $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Failed to acquire Azure access token for resource $Resource via Az PowerShell."
    }

    return $token.Trim()
}

function Get-HttpStatusCode {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception -or $null -eq $ErrorRecord.Exception.Response) {
        return $null
    }

    $response = $ErrorRecord.Exception.Response
    if ($response.StatusCode) {
        return [int]$response.StatusCode
    }

    return $null
}

function Write-HumanLog {
    param(
        [string]$Message,
        [string]$ForegroundColor = ""
    )

    if ($VerbosePreference -ne "Continue") {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ForegroundColor)) {
        Write-Host $Message
        return
    }

    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Write-Section {
    param([string]$Title)

    Write-HumanLog -Message ""
    Write-HumanLog -Message "==============================================================" -ForegroundColor "Cyan"
    Write-HumanLog -Message $Title -ForegroundColor "Cyan"
    Write-HumanLog -Message "==============================================================" -ForegroundColor "Cyan"
}

function Write-StatusLine {
    param(
        [string]$Label,
        [string]$Value
    )

    Write-HumanLog -Message ("{0,-24}: {1}" -f $Label, $Value)
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
        [string]$TableName
    )

    $headers = Get-TableHeaders -Token $Token
    $uri = "https://$StorageAccount.table.core.windows.net/Tables"
    $body = @{ TableName = $TableName }

    try {
        Invoke-RestWithRetry -Method "POST" -Uri $uri -Headers $headers -Body $body -MaxRetries 1 -BackoffSeconds 1 -TimeoutSeconds 15 | Out-Null
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($statusCode -ne 409) {
            throw
        }
    }
}

function Convert-TableKeyLiteral {
    param([string]$Value)

    return ([string]$Value).Replace("'", "''")
}

function Convert-AlertDedupeKeyToRowKey {
    param([string]$DedupeKey)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($DedupeKey)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    return -join ($hash | ForEach-Object { $_.ToString("x2") })
}

function Convert-ToThresholdArray {
    param(
        [AllowNull()]$RawThresholds,
        [AllowNull()]$LegacyBudget
    )

    if ($null -eq $RawThresholds) {
        if ($null -ne $LegacyBudget) {
            return @(Get-BudgetThresholds -Budget $LegacyBudget)
        }

        return @()
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

    $thresholds = @()
    foreach ($item in $rawItems) {
        $parsed = 0.0
        if ([double]::TryParse([string]$item, [ref]$parsed)) {
            $thresholds += [Math]::Round($parsed, 2)
        }
    }

    return @($thresholds | Sort-Object -Unique)
}

function Convert-ToBudgetRecord {
    param($Source)

    $subscriptionId = [string](Get-ObjectValue -Object $Source -Name "subscriptionId" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        $subscriptionId = [string](Get-ObjectValue -Object $Source -Name "SubscriptionID" -DefaultValue "")
    }
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        $subscriptionId = [string](Get-ObjectValue -Object $Source -Name "PartitionKey" -DefaultValue "")
    }

    $budgetName = [string](Get-ObjectValue -Object $Source -Name "budgetName" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($budgetName)) {
        $budgetName = [string](Get-ObjectValue -Object $Source -Name "name" -DefaultValue "")
    }
    if ([string]::IsNullOrWhiteSpace($budgetName)) {
        $budgetName = [string](Get-ObjectValue -Object $Source -Name "RowKey" -DefaultValue "")
    }

    $budgetAmountRaw = Get-ObjectValue -Object $Source -Name "budgetAmount" -DefaultValue $null
    if ($null -eq $budgetAmountRaw) {
        $budgetAmountRaw = Get-ObjectValue -Object $Source -Name "BudgetAmount" -DefaultValue $null
    }
    if ($null -eq $budgetAmountRaw) {
        $properties = Get-ObjectValue -Object $Source -Name "properties" -DefaultValue $null
        $budgetAmountRaw = Get-ObjectValue -Object $properties -Name "amount" -DefaultValue $null
    }

    $budgetAmount = 0.0
    $amountIsValid = [double]::TryParse([string]$budgetAmountRaw, [ref]$budgetAmount)

    $thresholdsRaw = Get-ObjectValue -Object $Source -Name "actualWarningThresholds" -DefaultValue $null
    if ($null -eq $thresholdsRaw) {
        $thresholdsRaw = Get-ObjectValue -Object $Source -Name "ActualWarningThresholds" -DefaultValue $null
    }
    if ($null -eq $thresholdsRaw) {
        $thresholdsRaw = Get-ObjectValue -Object $Source -Name "warningThresholds" -DefaultValue $null
    }
    if ($null -eq $thresholdsRaw) {
        $thresholdsRaw = Get-ObjectValue -Object $Source -Name "WarningThresholds" -DefaultValue $null
    }

    $recipientEmail = [string](Get-ObjectValue -Object $Source -Name "recipientEmail" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($recipientEmail)) {
        $recipientEmail = [string](Get-ObjectValue -Object $Source -Name "RecipientEmail" -DefaultValue "")
    }

    $thresholds = Convert-ToThresholdArray -RawThresholds $thresholdsRaw -LegacyBudget $Source

    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($budgetName) -or -not $amountIsValid -or $budgetAmount -le 0) {
        return $null
    }

    return [PSCustomObject]@{
        subscriptionId = $subscriptionId
        budgetName = $budgetName
        budgetAmount = [Math]::Round($budgetAmount, 2)
        actualWarningThresholds = $thresholds
        recipientEmail = $recipientEmail
        enabled = Get-ObjectValue -Object $Source -Name "enabled" -DefaultValue $true
    }
}

function Get-TableRows {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [string]$Filter = ""
    )

    $headers = Get-TableHeaders -Token $Token
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName()"

    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $uri = "{0}?`$filter={1}" -f $uri, [System.Uri]::EscapeDataString($Filter)
    }

    $rows = @()
    while (-not [string]::IsNullOrWhiteSpace($uri)) {
        $page = Invoke-RestWithRetry -Method "GET" -Uri $uri -Headers $headers -Body $null -MaxRetries 6 -BackoffSeconds 1.5 -TimeoutSeconds 30
        $rows += @(Get-ObjectValue -Object $page -Name "value" -DefaultValue @())

        $nextLink = [string](Get-ObjectValue -Object $page -Name "@odata.nextLink" -DefaultValue "")
        if ([string]::IsNullOrWhiteSpace($nextLink)) {
            $nextLink = [string](Get-ObjectValue -Object $page -Name "odata.nextLink" -DefaultValue "")
        }

        $uri = $nextLink
    }

    return @($rows)
}

function Get-BudgetRecordsFromTable {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName
    )

    $records = @()
    $rows = Get-TableRows -Token $Token -StorageAccount $StorageAccount -TableName $TableName
    foreach ($row in $rows) {
        $record = Convert-ToBudgetRecord -Source $row
        if ($null -eq $record) {
            Write-Warning ("Skipping invalid budget row from table '{0}'. RowKey='{1}' PartitionKey='{2}'." -f $TableName, ([string](Get-ObjectValue -Object $row -Name "RowKey" -DefaultValue "")), ([string](Get-ObjectValue -Object $row -Name "PartitionKey" -DefaultValue "")))
            continue
        }

        $records += $record
    }

    return @($records)
}

function Test-AlertAlreadySentInTable {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [string]$PartitionKey,
        [string]$RowKey
    )

    $headers = Get-TableHeaders -Token $Token
    $partitionLiteral = Convert-TableKeyLiteral -Value $PartitionKey
    $rowLiteral = Convert-TableKeyLiteral -Value $RowKey
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$partitionLiteral',RowKey='$rowLiteral')"

    try {
        Invoke-RestWithRetry -Method "GET" -Uri $uri -Headers $headers -Body $null -MaxRetries 1 -BackoffSeconds 1 -TimeoutSeconds 15 | Out-Null
        return $true
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 404) {
            return $false
        }

        throw
    }
}

function Register-SentAlertInTable {
    param(
        [string]$Token,
        [string]$StorageAccount,
        [string]$TableName,
        [hashtable]$Entity
    )

    $headers = Get-TableHeaders -Token $Token
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName"

    try {
        Invoke-RestWithRetry -Method "POST" -Uri $uri -Headers $headers -Body $Entity -MaxRetries 2 -BackoffSeconds 1 -TimeoutSeconds 15 | Out-Null
        return $true
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 409) {
            return $false
        }

        throw
    }
}

function Invoke-RestWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [AllowNull()]$Body,
        [int]$MaxRetries,
        [double]$BackoffSeconds,
        [int]$TimeoutSeconds
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Write-Verbose ("HTTP {0} {1} (attempt {2}/{3})" -f $Method, $Uri, $attempt, $MaxRetries)
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

function Get-AmortizedSpendBySubscription {
    param(
        [string]$Token,
        [string]$BillingAccountId,
        [string]$BillingProfileId,
        [datetime]$PeriodStart,
        [datetime]$PeriodEnd
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $scope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/billingProfiles/$BillingProfileId"
    $uri = "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-03-01"

    $body = @{
        type = "AmortizedCost"
        timeframe = "Custom"
        timePeriod = @{
            from = ($PeriodStart.ToString("yyyy-MM-dd") + "T00:00:00Z")
            to = ($PeriodEnd.ToString("yyyy-MM-dd") + "T23:59:59Z")
        }
        dataset = @{
            granularity = "None"
            aggregation = @{
                PreTaxCostUSD = @{
                    name = "PreTaxCostUSD"
                    function = "Sum"
                }
            }
            grouping = @(
                @{
                    type = "Dimension"
                    name = "SubscriptionId"
                },
                @{
                    type = "Dimension"
                    name = "SubscriptionName"
                }
            )
        }
    }

    $pages = @()
    Write-HumanLog -Message "Requesting Cost Management data..." -ForegroundColor "Cyan"
    $page = Invoke-RestWithRetry -Method "POST" -Uri $uri -Headers $headers -Body $body -MaxRetries 6 -BackoffSeconds 1.5 -TimeoutSeconds 30
    $pages += $page
    $firstRowCount = @($page.properties.rows).Count
    Write-HumanLog -Message ("  Page 1: retrieved {0} grouped cost rows" -f $firstRowCount) -ForegroundColor "Green"

    $pageProperties = Get-ObjectValue -Object $page -Name "properties" -DefaultValue $null
    $nextLink = [string](Get-ObjectValue -Object $pageProperties -Name "nextLink" -DefaultValue "")
    $pageNumber = 1
    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        $pageNumber++
        Write-Verbose ("Following Cost Management nextLink for page {0}" -f $pageNumber)
        try {
            $page = Invoke-RestWithRetry -Method "GET" -Uri $nextLink -Headers $headers -Body $null -MaxRetries 6 -BackoffSeconds 1.5 -TimeoutSeconds 30
        }
        catch {
            $page = Invoke-RestWithRetry -Method "POST" -Uri $nextLink -Headers $headers -Body $body -MaxRetries 6 -BackoffSeconds 1.5 -TimeoutSeconds 30
        }

        $pages += $page
        Write-HumanLog -Message ("  Page {0}: retrieved {1} grouped cost rows" -f $pageNumber, @($page.properties.rows).Count) -ForegroundColor "Green"
        $pageProperties = Get-ObjectValue -Object $page -Name "properties" -DefaultValue $null
        $nextLink = [string](Get-ObjectValue -Object $pageProperties -Name "nextLink" -DefaultValue "")
    }

    $result = @{}
    $subscriptionNameById = @{}
    foreach ($rawPage in $pages) {
        $columns = @($rawPage.properties.columns)
        $rows = @($rawPage.properties.rows)

        $subscriptionIndex = -1
        $subscriptionNameIndex = -1
        $costIndex = -1
        for ($i = 0; $i -lt $columns.Count; $i++) {
            if ($columns[$i].name -eq "SubscriptionId") {
                $subscriptionIndex = $i
            }
            if ($columns[$i].name -eq "SubscriptionName") {
                $subscriptionNameIndex = $i
            }
            if ($columns[$i].name -eq "PreTaxCostUSD") {
                $costIndex = $i
            }
        }

        if ($subscriptionIndex -lt 0 -or $costIndex -lt 0) {
            continue
        }

        foreach ($row in $rows) {
            $subId = [string]$row[$subscriptionIndex]
            if ([string]::IsNullOrWhiteSpace($subId)) {
                Write-Verbose "Skipping cost row with blank SubscriptionId."
                continue
            }

            if ($subscriptionNameIndex -ge 0) {
                $subName = [string]$row[$subscriptionNameIndex]
                if (-not [string]::IsNullOrWhiteSpace($subName)) {
                    $subscriptionNameById[$subId] = $subName
                }
            }
            $cost = [double]$row[$costIndex]
            if (-not $result.ContainsKey($subId)) {
                $result[$subId] = 0.0
            }
            $result[$subId] += $cost
        }
    }

    return @{
        spendBySubscription = $result
        subscriptionNameById = $subscriptionNameById
    }
}

function Get-BudgetThresholds {
    param([AllowNull()]$Budget)

    $properties = Get-ObjectValue -Object $Budget -Name "properties" -DefaultValue $null
    $notifications = Get-ObjectValue -Object $properties -Name "notifications" -DefaultValue $null
    if ($null -eq $notifications) {
        return @()
    }

    $values = @()

    if ($notifications -is [hashtable]) {
        $notificationEntries = $notifications.Values
    }
    else {
        $notificationEntries = @($notifications.PSObject.Properties | ForEach-Object { $_.Value })
    }

    foreach ($notification in @($notificationEntries)) {
        $enabled = Get-ObjectValue -Object $notification -Name "enabled" -DefaultValue $true
        if (-not [bool]$enabled) {
            continue
        }

        $rawThreshold = Get-ObjectValue -Object $notification -Name "threshold" -DefaultValue $null
        if ($null -eq $rawThreshold) {
            continue
        }

        $parsed = 0.0
        if ([double]::TryParse([string]$rawThreshold, [ref]$parsed)) {
            $values += [Math]::Round($parsed, 2)
        }
    }

    return @($values | Sort-Object -Unique)
}

function Get-ObjectValue {
    param(
        [AllowNull()]$Object,
        [string]$Name,
        $DefaultValue
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $DefaultValue
}

function Get-AlertDedupeKey {
    param(
        [string]$SubscriptionId,
        [string]$BudgetName,
        [double]$Threshold,
        [string]$Period
    )

    return "{0}|{1}|{2}|{3}" -f $SubscriptionId.Trim().ToLowerInvariant(), $BudgetName.Trim().ToLowerInvariant(), ([Math]::Round($Threshold, 2).ToString("0.##")), $Period.Trim().ToLowerInvariant()
}

function Test-AlertAlreadySent {
    param(
        [hashtable]$State,
        [string]$Key
    )

    if ($null -eq $State -or $null -eq $State.sent -or $State.sent -isnot [hashtable]) {
        return $false
    }

    return $State.sent.ContainsKey($Key)
}

function Register-SentAlert {
    param(
        [hashtable]$State,
        [string]$Key,
        [hashtable]$Metadata
    )

    if ($null -eq $State.sent -or $State.sent -isnot [hashtable]) {
        $State.sent = @{}
    }

    $State.sent[$Key] = $Metadata
}

function Send-BudgetAlert {
    param(
        [string]$SubscriptionId,
        [string]$SubscriptionName,
        [string]$BudgetName,
        [string]$RecipientEmail,
        [double]$ThresholdPercent,
        [double]$UtilizationPercent,
        [double]$AmortizedSpend
    )

    if ([string]::IsNullOrWhiteSpace($RecipientEmail)) {
        return @{ status = "skipped"; detail = "no recipient email configured" }
    }

    # try {
    #     $subject = "Budget Alert: {0} at {1}% utilization" -f $BudgetName, $UtilizationPercent
    #     $body = @"
    # Budget Alert for {0} ({1})
    #
    # Budget: {2}
    # Threshold: {3}%
    # Current Utilization: {4}%
    # Current Spend: \${5:F2}
    #
    # Please review your spending.
    # "@ -f $SubscriptionName, $SubscriptionId, $BudgetName, $ThresholdPercent, $UtilizationPercent, $AmortizedSpend
    #
    #     Send-MailMessage -To $RecipientEmail -Subject $subject -Body $body -SmtpServer "localhost" -From "budget-monitor@azure" -ErrorAction Stop
    #     return @{ status = "sent"; detail = $RecipientEmail }
    # }
    # catch {
    #     return @{ status = "failed"; detail = $_.Exception.Message }
    # }

    return @{ status = "sent"; detail = ("simulated delivery to {0}" -f $RecipientEmail) }
}

function Write-RunEvent {
    param(
        [hashtable]$EventRecord,
        [string]$LogPath
    )

    $eventType = [string](Get-ObjectValue -Object $EventRecord -Name "type" -DefaultValue "event")
    $line = Format-LogEventLine -EventRecord $EventRecord

    $color = switch ($eventType) {
        "job_start"               { "Blue" }
        "budget_exceeded_warning" { "Yellow" }
        "alert_sent"              { "Cyan" }
        "alert_not_sent"          { "Red" }
        "alert_already_sent"      { "DarkGray" }
        "run_summary"             { "Green" }
        default                   { "White" }
    }
    Write-Host $line -ForegroundColor $color

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        return
    }

    $parent = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Format-LogEventLine {
    param([hashtable]$EventRecord)

    $timestampUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $eventType = [string](Get-ObjectValue -Object $EventRecord -Name "type" -DefaultValue "event")

    if ($eventType -eq "alert") {
        $subscriptionName = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionName" -DefaultValue "")
        $subscriptionId = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionId" -DefaultValue "")
        $period = [string](Get-ObjectValue -Object $EventRecord -Name "period" -DefaultValue "")
        $threshold = [string](Get-ObjectValue -Object $EventRecord -Name "thresholdPercent" -DefaultValue "")
        $utilization = [string](Get-ObjectValue -Object $EventRecord -Name "utilizationPercent" -DefaultValue "")
        $budget = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionBudget" -DefaultValue "")
        $spend = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionAmortizedSpend" -DefaultValue "")

        return "[{0}] ALERT period={1} sub={2} ({3}) threshold={4}% utilization={5}% budget={6} spend={7}" -f $timestampUtc, $period, $subscriptionName, $subscriptionId, $threshold, $utilization, $budget, $spend
    }

    if ($eventType -eq "budget_exceeded_warning") {
        $subscriptionName = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionName" -DefaultValue "")
        $subscriptionId = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionId" -DefaultValue "")
        $budgetName = [string](Get-ObjectValue -Object $EventRecord -Name "budgetName" -DefaultValue "")
        $budgetAmount = [string](Get-ObjectValue -Object $EventRecord -Name "budgetAmount" -DefaultValue "")
        $spend = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionAmortizedSpend" -DefaultValue "")
        $utilization = [string](Get-ObjectValue -Object $EventRecord -Name "utilizationPercent" -DefaultValue "")

        return "[{0}] BUDGET_EXCEEDED sub={1} ({2}) budget={3} amount={4} spend={5} utilization={6}%" -f $timestampUtc, $subscriptionId, $subscriptionName, $budgetName, $budgetAmount, $spend, $utilization
    }

    if ($eventType -eq "job_start") {
        $period = [string](Get-ObjectValue -Object $EventRecord -Name "period" -DefaultValue "")
        return "[{0}] JOB_START period={1}" -f $timestampUtc, $period
    }

    if ($eventType -eq "run_summary") {
        $runStatus = [string](Get-ObjectValue -Object $EventRecord -Name "runStatus" -DefaultValue "")
        $period = [string](Get-ObjectValue -Object $EventRecord -Name "period" -DefaultValue "")
        $evaluated = [string](Get-ObjectValue -Object $EventRecord -Name "evaluatedSubscriptions" -DefaultValue "")
        $matchingSubscriptions = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionsWithMatchingBudgets" -DefaultValue "")
        $budgetsEvaluated = [string](Get-ObjectValue -Object $EventRecord -Name "budgetsEvaluated" -DefaultValue "")
        $budgetsExceeded = [string](Get-ObjectValue -Object $EventRecord -Name "budgetsExceeded" -DefaultValue "")

        return "[{0}] RUN_SUMMARY period={1} status={2} evaluatedSubs={3} matchingBudgetSubs={4} budgetsEvaluated={5} budgetsExceeded={6}" -f $timestampUtc, $period, $runStatus, $evaluated, $matchingSubscriptions, $budgetsEvaluated, $budgetsExceeded
    }

    if ($eventType -eq "alert_sent") {
        $subscriptionId = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionId" -DefaultValue "")
        $subscriptionName = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionName" -DefaultValue "")
        $budgetName = [string](Get-ObjectValue -Object $EventRecord -Name "budgetName" -DefaultValue "")
        $period = [string](Get-ObjectValue -Object $EventRecord -Name "period" -DefaultValue "")
        $threshold = [string](Get-ObjectValue -Object $EventRecord -Name "thresholdPercent" -DefaultValue "")
        $utilization = [string](Get-ObjectValue -Object $EventRecord -Name "utilizationPercent" -DefaultValue "")
        $delivery = Get-ObjectValue -Object $EventRecord -Name "delivery" -DefaultValue @{}
        $status = [string](Get-ObjectValue -Object $delivery -Name "status" -DefaultValue "")

        return "[{0}] ALERT_SENT period={1} sub={2} ({3}) budget={4} threshold={5}% utilization={6}% status={7}" -f $timestampUtc, $period, $subscriptionId, $subscriptionName, $budgetName, $threshold, $utilization, $status
    }

    if ($eventType -eq "alert_not_sent") {
        $subscriptionId = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionId" -DefaultValue "")
        $subscriptionName = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionName" -DefaultValue "")
        $budgetName = [string](Get-ObjectValue -Object $EventRecord -Name "budgetName" -DefaultValue "")
        $period = [string](Get-ObjectValue -Object $EventRecord -Name "period" -DefaultValue "")
        $threshold = [string](Get-ObjectValue -Object $EventRecord -Name "thresholdPercent" -DefaultValue "")
        $utilization = [string](Get-ObjectValue -Object $EventRecord -Name "utilizationPercent" -DefaultValue "")
        $delivery = Get-ObjectValue -Object $EventRecord -Name "delivery" -DefaultValue @{}
        $status = [string](Get-ObjectValue -Object $delivery -Name "status" -DefaultValue "")
        $detail = [string](Get-ObjectValue -Object $delivery -Name "detail" -DefaultValue "")

        return "[{0}] ALERT_NOT_SENT period={1} sub={2} ({3}) budget={4} threshold={5}% utilization={6}% status={7} detail={8}" -f $timestampUtc, $period, $subscriptionId, $subscriptionName, $budgetName, $threshold, $utilization, $status, $detail
    }

    if ($eventType -eq "alert_already_sent") {
        $subscriptionId = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionId" -DefaultValue "")
        $subscriptionName = [string](Get-ObjectValue -Object $EventRecord -Name "subscriptionName" -DefaultValue "")
        $budgetName = [string](Get-ObjectValue -Object $EventRecord -Name "budgetName" -DefaultValue "")
        $period = [string](Get-ObjectValue -Object $EventRecord -Name "period" -DefaultValue "")
        $threshold = [string](Get-ObjectValue -Object $EventRecord -Name "thresholdPercent" -DefaultValue "")
        $utilization = [string](Get-ObjectValue -Object $EventRecord -Name "utilizationPercent" -DefaultValue "")

        return "[{0}] ALERT_ALREADY_SENT period={1} sub={2} ({3}) budget={4} threshold={5}% utilization={6}%" -f $timestampUtc, $period, $subscriptionId, $subscriptionName, $budgetName, $threshold, $utilization
    }

    return "[{0}] {1} {2}" -f $timestampUtc, $eventType.ToUpperInvariant(), ($EventRecord | ConvertTo-Json -Compress -Depth 20)
}

$resolvedConfigFile = Resolve-RelativePath -Path $ConfigFile
$resolvedLogFile = if ($ExecutionMode -eq "Local") { Resolve-RelativePath -Path $LogFile } else { "" }
$resolvedSpendFile = if ($ExecutionMode -eq "Local") { Resolve-RelativePath -Path $SpendFile } else { "" }
$resolvedBudgetFile = if ($ExecutionMode -eq "Local") { Resolve-RelativePath -Path $BudgetFile } else { "" }

$billingAccountId = [string]$BillingAccountId
$billingProfileId = [string]$BillingProfileId
$stateStorageAccount = [string]$StorageAccount
$budgetTableName = [string]$BudgetTable
$alertStateTableName = [string]$AlertStateTable
$statePartitionPrefix = if ([string]::IsNullOrWhiteSpace($PartitionPrefix)) { "amortized-budget" } else { [string]$PartitionPrefix }

if ($ExecutionMode -eq "AzureAutomation") {
    if (-not [string]::IsNullOrWhiteSpace($SpendFile) -or -not [string]::IsNullOrWhiteSpace($BudgetFile)) {
        throw "AzureAutomation mode does not use spend or budget files."
    }

    $SpendData = "CostAPI"
    $BudgetData = "AzureTable"
    $StateData = "AzureTable"

    if ([string]::IsNullOrWhiteSpace($billingAccountId) -or [string]::IsNullOrWhiteSpace($billingProfileId)) {
        throw "AzureAutomation mode requires BillingAccountId and BillingProfileId."
    }

    if ([string]::IsNullOrWhiteSpace($stateStorageAccount) -or [string]::IsNullOrWhiteSpace($budgetTableName) -or [string]::IsNullOrWhiteSpace($alertStateTableName)) {
        throw "AzureAutomation mode requires StorageAccount, BudgetTable, and AlertStateTable."
    }
}

$needsConfig = ($ExecutionMode -eq "Local") -and (($SpendData -eq "CostAPI") -or ($BudgetData -eq "AzureTable") -or ($StateData -eq "AzureTable"))
if ($needsConfig) {
    Test-ConfigSchema -ConfigFile $resolvedConfigFile
    $config = Import-Config -ConfigFile $resolvedConfigFile

    if ([string]::IsNullOrWhiteSpace($billingAccountId)) {
        $billingAccountId = [string](Get-ObjectValue -Object $config -Name "billing_account_id" -DefaultValue "")
    }

    if ([string]::IsNullOrWhiteSpace($billingProfileId)) {
        $billingProfileId = [string](Get-ObjectValue -Object $config -Name "billing_profile_id" -DefaultValue "")
    }

    $stateConfig = Get-ObjectValue -Object $config -Name "state" -DefaultValue @{}
    if ([string]::IsNullOrWhiteSpace($stateStorageAccount)) {
        $stateStorageAccount = [string](Get-ObjectValue -Object $stateConfig -Name "storage_account" -DefaultValue "")
    }
    if ([string]::IsNullOrWhiteSpace($budgetTableName)) {
        $budgetTableName = [string](Get-ObjectValue -Object $stateConfig -Name "budget_table" -DefaultValue "")
    }
    if ([string]::IsNullOrWhiteSpace($alertStateTableName)) {
        $alertStateTableName = [string](Get-ObjectValue -Object $stateConfig -Name "alert_state_table" -DefaultValue "")
    }
    if ([string]::IsNullOrWhiteSpace($statePartitionPrefix)) {
        $statePartitionPrefix = [string](Get-ObjectValue -Object $stateConfig -Name "partition_prefix" -DefaultValue "amortized-budget")
    }
}

if ($ExecutionMode -eq "Local" -and $SpendData -eq "CostAPI" -and [string]::IsNullOrWhiteSpace($billingAccountId)) {
    throw "BillingAccountId is required when SpendData is CostAPI."
}

if ($ExecutionMode -eq "Local" -and $BudgetData -eq "AzureTable" -and ([string]::IsNullOrWhiteSpace($stateStorageAccount) -or [string]::IsNullOrWhiteSpace($budgetTableName))) {
    throw "StorageAccount and BudgetTable are required when BudgetData is AzureTable."
}

if ($ExecutionMode -eq "Local" -and $StateData -eq "AzureTable" -and ([string]::IsNullOrWhiteSpace($stateStorageAccount) -or [string]::IsNullOrWhiteSpace($alertStateTableName))) {
    throw "StorageAccount and AlertStateTable are required when StateData is AzureTable."
}

$state = @{ sent = @{} }
$stateTableToken = $null

$today = (Get-Date).ToUniversalTime().Date
$periodStart = Get-Date -Date ("{0}-01" -f $today.ToString("yyyy-MM"))
$periodStart = $periodStart.ToUniversalTime().Date
$periodKey = $periodStart.ToString("yyyy-MM")
$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

Write-Section -Title "Amortized Budget Monitor"
Write-StatusLine -Label "Execution mode" -Value $ExecutionMode
Write-StatusLine -Label "Spend data" -Value $SpendData
Write-StatusLine -Label "Budget data" -Value $BudgetData
Write-StatusLine -Label "State data" -Value $StateData
Write-StatusLine -Label "Config file" -Value $(if ($ExecutionMode -eq "Local") { $resolvedConfigFile } else { "(not used)" })
Write-StatusLine -Label "Run ID" -Value $runId
Write-StatusLine -Label "Period" -Value $periodKey
Write-StatusLine -Label "State backend" -Value $(if ($StateData -eq "AzureTable") { "Azure Table" } else { "Memory" })
Write-StatusLine -Label "Storage account" -Value $(if ([string]::IsNullOrWhiteSpace($stateStorageAccount)) { "(not set)" } else { $stateStorageAccount })
Write-StatusLine -Label "Budget table" -Value $(if ([string]::IsNullOrWhiteSpace($budgetTableName)) { "(not set)" } else { $budgetTableName })
Write-StatusLine -Label "Alert state table" -Value $(if ([string]::IsNullOrWhiteSpace($alertStateTableName)) { "(not set)" } else { $alertStateTableName })
Write-Verbose ("Billing account ID: {0}" -f $billingAccountId)
Write-Verbose ("Billing profile ID: {0}" -f $billingProfileId)

$effectiveLogFile = $resolvedLogFile
if ($ExecutionMode -eq "AzureAutomation") {
    $effectiveLogFile = ""
}

Write-StatusLine -Label "Log file" -Value $(if ([string]::IsNullOrWhiteSpace($effectiveLogFile)) { "(stdout only)" } else { $effectiveLogFile })

$useSpendFile = ($ExecutionMode -eq "Local") -and ($SpendData -eq "File")
$useBudgetFile = ($ExecutionMode -eq "Local") -and ($BudgetData -eq "File")
$dedupeMode = if ($StateData -eq "AzureTable") { "AzureTable" } else { "Memory" }
$requiresStorageTableAccess = ($BudgetData -eq "AzureTable") -or ($StateData -eq "AzureTable")

Write-StatusLine -Label "Spend source" -Value $SpendData
Write-StatusLine -Label "Budget source" -Value $BudgetData
Write-StatusLine -Label "Dedupe mode" -Value $dedupeMode

if ($SpendData -eq "File" -and [string]::IsNullOrWhiteSpace($resolvedSpendFile)) {
    throw "SpendFile is required when SpendData is File."
}

if ($BudgetData -eq "File" -and [string]::IsNullOrWhiteSpace($resolvedBudgetFile)) {
    throw "BudgetFile is required when BudgetData is File."
}

$token = $null
$spendBySubscription = @{}
$budgetFileRows = @()
$subscriptionNameById = @{}
$budgetRecords = @()
$budgetRecordsBySubscription = @{}

if ($requiresStorageTableAccess) {
    $stateTableToken = Get-AccessToken -Resource "https://storage.azure.com/"
}

if ($StateData -eq "AzureTable") {
    Initialize-Table -Token $stateTableToken -StorageAccount $stateStorageAccount -TableName $alertStateTableName
}

if ($useBudgetFile) {
    Write-Section -Title "Budget File Mode"
    Write-StatusLine -Label "Budget file" -Value $resolvedBudgetFile
    $budgetFileRows = Import-BudgetFile -Path $resolvedBudgetFile

    foreach ($budgetRow in $budgetFileRows) {
        $normalized = Convert-ToBudgetRecord -Source $budgetRow
        if ($null -eq $normalized) {
            continue
        }

        $budgetRecords += $normalized
        if (-not $budgetRecordsBySubscription.ContainsKey($normalized.subscriptionId)) {
            $budgetRecordsBySubscription[$normalized.subscriptionId] = @()
        }

        $budgetRecordsBySubscription[$normalized.subscriptionId] += $normalized

        if (-not $subscriptionNameById.ContainsKey($normalized.subscriptionId)) {
            $budgetFileSubName = [string](Get-ObjectValue -Object $budgetRow -Name "subscriptionName" -DefaultValue "")
            if ([string]::IsNullOrWhiteSpace($budgetFileSubName)) {
                $budgetFileSubName = [string]$normalized.subscriptionId
            }

            $subscriptionNameById[[string]$normalized.subscriptionId] = $budgetFileSubName
        }
    }

    Write-HumanLog -Message ("Loaded {0} budget file rows" -f @($budgetRecords).Count) -ForegroundColor "Green"
}
else {
    Write-Section -Title "Budget Table Mode"
    Initialize-Table -Token $stateTableToken -StorageAccount $stateStorageAccount -TableName $budgetTableName

    $budgetRecords = Get-BudgetRecordsFromTable -Token $stateTableToken -StorageAccount $stateStorageAccount -TableName $budgetTableName

    if ($null -eq $budgetRecords) {
        $budgetRecords = @()
    }

    foreach ($record in $budgetRecords) {
        if (-not $budgetRecordsBySubscription.ContainsKey($record.subscriptionId)) {
            $budgetRecordsBySubscription[$record.subscriptionId] = @()
        }

        $budgetRecordsBySubscription[$record.subscriptionId] += $record
    }

    Write-StatusLine -Label "Budget rows loaded" -Value (@($budgetRecords).Count).ToString()
}

if ($useSpendFile) {
    Write-Section -Title "Spend File Mode"
    Write-StatusLine -Label "Spend file" -Value $resolvedSpendFile
    $spendFileEntries = Import-SpendFile -Path $resolvedSpendFile
    
    # Build lookups from spend file entries
    $spendBySubscription = @{}
    $subscriptionNameById = @{}
    foreach ($entry in @($spendFileEntries)) {
        $subId = [string](Get-ObjectValue -Object $entry -Name "SubscriptionID" -DefaultValue "")
        $subName = [string](Get-ObjectValue -Object $entry -Name "SubscriptionName" -DefaultValue "")
        $cost = [double](Get-ObjectValue -Object $entry -Name "PreTaxCostUSD" -DefaultValue 0.0)
        
        if (-not [string]::IsNullOrWhiteSpace($subId)) {
            $spendBySubscription[$subId] = $cost
            if (-not [string]::IsNullOrWhiteSpace($subName)) {
                $subscriptionNameById[$subId] = $subName
            }
        }
    }
    
    Write-HumanLog -Message ("Loaded {0} spend file rows" -f @($spendFileEntries).Count) -ForegroundColor "Green"
}
else {
    Write-Section -Title "Cost API Mode"
    if ([string]::IsNullOrWhiteSpace($billingAccountId) -or [string]::IsNullOrWhiteSpace($billingProfileId)) {
        throw "BillingAccountId and BillingProfileId are required."
    }

    Write-StatusLine -Label "Billing account" -Value $billingAccountId
    Write-StatusLine -Label "Billing profile" -Value $billingProfileId
    $token = Get-AccessToken -Resource "https://management.azure.com/"
    $costData = Get-AmortizedSpendBySubscription -Token $token -BillingAccountId $billingAccountId -BillingProfileId $billingProfileId -PeriodStart $periodStart -PeriodEnd $today
    $spendBySubscription = Get-ObjectValue -Object $costData -Name "spendBySubscription" -DefaultValue @{}
    $subscriptionNameById = Get-ObjectValue -Object $costData -Name "subscriptionNameById" -DefaultValue @{}
    Write-HumanLog -Message ("Loaded spend totals for {0} subscriptions" -f $spendBySubscription.Count) -ForegroundColor "Green"
}

$subscriptionEvaluations = New-Object System.Collections.ArrayList
$errors = @()

$excludedCount = 0
$subscriptionsWithMatchingBudgets = 0
$budgetsEvaluated = 0
$budgetsExceeded = 0

Write-RunEvent -EventRecord @{
    type = "job_start"
    runId = $runId
    period = $periodKey
    billingAccountId = $billingAccountId
    billingProfileId = $billingProfileId
} -LogPath $effectiveLogFile

Write-Section -Title "Budget Evaluation"
Write-HumanLog -Message ("Evaluating {0} subscriptions with spend data" -f $spendBySubscription.Count) -ForegroundColor "Cyan"

foreach ($subId in @($spendBySubscription.Keys)) {
    $subId = [string]$subId
    $subName = $subId
    if ($subscriptionNameById.ContainsKey($subId)) {
        $subName = [string]$subscriptionNameById[$subId]
    }

    Write-Verbose ("Evaluating subscription {0} ({1})" -f $subName, $subId)

    if ([string]::IsNullOrWhiteSpace($subId)) {
        Write-HumanLog -Message "  (blank subscription id): skipping budget lookup for unattributed cost row" -ForegroundColor "DarkYellow"
        continue
    }

    $subscriptionSpend = [double]$spendBySubscription[$subId]
    Write-Verbose ("Subscription {0} spend = {1}" -f $subId, [Math]::Round($subscriptionSpend, 2))

    $matchingBudgets = @()
    if ($budgetRecordsBySubscription.ContainsKey($subId)) {
        $matchingBudgets = @(
            $budgetRecordsBySubscription[$subId] | Where-Object {
                $_.enabled
            }
        )
    }

    if (@($matchingBudgets).Count -eq 0) {
        $excludedCount++
        Write-HumanLog -Message ("  {0} | {1} : no matching budgets found" -f $subId, $subName) -ForegroundColor "DarkYellow"
        continue
    }

    $subscriptionsWithMatchingBudgets++
    Write-HumanLog -Message ("  {0}: {1} matching budget(s)" -f $subName, @($matchingBudgets).Count) -ForegroundColor "Yellow"

    foreach ($budget in $matchingBudgets) {
        $budgetName = [string](Get-ObjectValue -Object $budget -Name "budgetName" -DefaultValue "")
        $budgetAmount = [double](Get-ObjectValue -Object $budget -Name "budgetAmount" -DefaultValue 0)
        $thresholds = @(Get-ObjectValue -Object $budget -Name "actualWarningThresholds" -DefaultValue @())
        if (@($thresholds).Count -eq 0) {
            $thresholds = @(Get-ObjectValue -Object $budget -Name "warningThresholds" -DefaultValue @())
        }
        $recipientEmail = [string](Get-ObjectValue -Object $budget -Name "recipientEmail" -DefaultValue "")

        $utilization = [Math]::Round(($subscriptionSpend / $budgetAmount) * 100.0, 2)
        Write-Verbose ("Budget '{0}' amount={1} spend={2} utilization={3}% thresholds=[{4}]" -f $budgetName, ([Math]::Round($budgetAmount, 2)), ([Math]::Round($subscriptionSpend, 2)), $utilization, (($thresholds | ForEach-Object { [string]$_ }) -join ","))

        [void]$subscriptionEvaluations.Add(@{
            subscriptionId = $subId
            subscriptionName = $subName
            budgetName = $budgetName
            budgetAmount = [Math]::Round($budgetAmount, 2)
            thresholds = $thresholds
            amortizedSpend = [Math]::Round($subscriptionSpend, 2)
            utilizationPercent = $utilization
            exceeded = ($subscriptionSpend -ge $budgetAmount)
        })

        $budgetsEvaluated++

        if ($subscriptionSpend -ge $budgetAmount) {
            $budgetsExceeded++
            Write-Warning ("Budget exceeded: sub='{0}' ({1}) budget='{2}' amount={3} spend={4} utilization={5}% thresholds=[{6}]" -f $subName, $subId, $budgetName, ([Math]::Round($budgetAmount, 2)), ([Math]::Round($subscriptionSpend, 2)), $utilization, (($thresholds | ForEach-Object { [string]$_ }) -join ","))

            Write-RunEvent -EventRecord @{
                type = "budget_exceeded_warning"
                runId = $runId
                period = $periodKey
                subscriptionId = $subId
                subscriptionName = $subName
                budgetName = $budgetName
                budgetAmount = [Math]::Round($budgetAmount, 2)
                thresholds = $thresholds
                recipientEmail = $recipientEmail
                utilizationPercent = $utilization
                subscriptionAmortizedSpend = [Math]::Round($subscriptionSpend, 2)
            } -LogPath $effectiveLogFile

            # Pass 1: collect newly-breached thresholds (dedupe check only, no webhook calls)
            $pendingThresholds = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($threshold in $thresholds) {
                if ($utilization -lt [double]$threshold) {
                    continue
                }

                $dedupeKey = Get-AlertDedupeKey -SubscriptionId $subId -BudgetName $budgetName -Threshold ([double]$threshold) -Period $periodKey
                $alertAlreadySent = $false
                if ($dedupeMode -eq "table") {
                    $dedupePartitionKey = "{0}:{1}" -f $statePartitionPrefix, $periodKey
                    $dedupeRowKey = Convert-AlertDedupeKeyToRowKey -DedupeKey $dedupeKey
                    $alertAlreadySent = Test-AlertAlreadySentInTable -Token $stateTableToken -StorageAccount $stateStorageAccount -TableName $alertStateTableName -PartitionKey $dedupePartitionKey -RowKey $dedupeRowKey
                }
                else {
                    $alertAlreadySent = Test-AlertAlreadySent -State $state -Key $dedupeKey
                }

                if ($alertAlreadySent) {
                    Write-RunEvent -EventRecord @{
                        type = "alert_already_sent"
                        runId = $runId
                        period = $periodKey
                        subscriptionId = $subId
                        subscriptionName = $subName
                        budgetName = $budgetName
                        thresholdPercent = [double]$threshold
                        utilizationPercent = $utilization
                        dedupeKey = $dedupeKey
                    } -LogPath $effectiveLogFile
                    continue
                }

                $pendingThresholds.Add([PSCustomObject]@{
                    threshold = [double]$threshold
                    dedupeKey = $dedupeKey
                })
            }

            # Determine the single highest newly-breached threshold — only that one triggers the webhook
            $highestNewThreshold = if (@($pendingThresholds).Count -gt 0) {
                ($pendingThresholds | Measure-Object -Property threshold -Maximum).Maximum
            } else { $null }

            # Pass 2: write state for all pending thresholds; send email only for the highest
            foreach ($pending in $pendingThresholds) {
                $threshold = $pending.threshold
                $dedupeKey = $pending.dedupeKey

                if ($threshold -ne $highestNewThreshold) {
                    $deliveryResult = @{ status = "suppressed"; detail = ("lower threshold suppressed; highest={0}" -f $highestNewThreshold) }
                }
                else {
                    $deliveryResult = Send-BudgetAlert -SubscriptionId $subId -SubscriptionName $subName -BudgetName $budgetName -RecipientEmail $recipientEmail -ThresholdPercent $threshold -UtilizationPercent $utilization -AmortizedSpend $subscriptionSpend
                }

                if ([string]$deliveryResult.status -in @("sent", "suppressed", "skipped", "failed")) {
                    if ($dedupeMode -eq "table") {
                        $dedupePartitionKey = "{0}:{1}" -f $statePartitionPrefix, $periodKey
                        $dedupeRowKey = Convert-AlertDedupeKeyToRowKey -DedupeKey $dedupeKey
                        $inserted = Register-SentAlertInTable -Token $stateTableToken -StorageAccount $stateStorageAccount -TableName $alertStateTableName -Entity @{
                            PartitionKey = $dedupePartitionKey
                            RowKey = $dedupeRowKey
                            period = $periodKey
                            subscriptionId = $subId
                            subscriptionName = $subName
                            budgetName = $budgetName
                            budgetAmount = [Math]::Round($budgetAmount, 2)
                            thresholdPercent = $threshold
                            utilizationPercent = $utilization
                            subscriptionAmortizedSpend = [Math]::Round($subscriptionSpend, 2)
                            recipientEmail = $recipientEmail
                            deliveryStatus = [string]$deliveryResult.status
                            deliveryDetail = [string]$deliveryResult.detail
                        }

                        if (-not $inserted) {
                            Write-RunEvent -EventRecord @{
                                type = "alert_already_sent"
                                runId = $runId
                                period = $periodKey
                                subscriptionId = $subId
                                subscriptionName = $subName
                                budgetName = $budgetName
                                thresholdPercent = $threshold
                                utilizationPercent = $utilization
                                dedupeKey = $dedupeKey
                            } -LogPath $effectiveLogFile
                            continue
                        }
                    }
                    else {
                        Register-SentAlert -State $state -Key $dedupeKey -Metadata @{
                            sentAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                            thresholdPercent = $threshold
                            budgetName = $budgetName
                            deliveryStatus = [string]$deliveryResult.status
                            deliveryDetail = [string]$deliveryResult.detail
                        }
                    }

                    Write-RunEvent -EventRecord @{
                        type = "alert_sent"
                        runId = $runId
                        period = $periodKey
                        subscriptionId = $subId
                        subscriptionName = $subName
                        budgetName = $budgetName
                        thresholdPercent = $threshold
                        utilizationPercent = $utilization
                        dedupeKey = $dedupeKey
                        delivery = @{
                            status = [string]$deliveryResult.status
                            detail = [string]$deliveryResult.detail
                        }
                    } -LogPath $effectiveLogFile
                }
                else {
                    Write-RunEvent -EventRecord @{
                        type = "alert_not_sent"
                        runId = $runId
                        period = $periodKey
                        subscriptionId = $subId
                        subscriptionName = $subName
                        budgetName = $budgetName
                        thresholdPercent = $threshold
                        utilizationPercent = $utilization
                        dedupeKey = $dedupeKey
                        delivery = @{
                            status = [string]$deliveryResult.status
                            detail = [string]$deliveryResult.detail
                        }
                    } -LogPath $effectiveLogFile
                }
            }
        }
    }
}

$runStatus = if ($errors.Count -gt 0) { "partial_success" } else { "success" }
$errorCount = $errors.Count
$summary = @{
    type = "run_summary"
    runId = $runId
    runStatus = $runStatus
    period = $periodKey
    evaluatedSubscriptions = @($subscriptionEvaluations).Count
    subscriptionsWithMatchingBudgets = $subscriptionsWithMatchingBudgets
    excludedSubscriptions = $excludedCount
    budgetsEvaluated = $budgetsEvaluated
    budgetsExceeded = $budgetsExceeded
    errors = $errors
}

Write-Section -Title "Run Summary"
Write-StatusLine -Label "Run status" -Value $runStatus
Write-StatusLine -Label "Evaluated budgets" -Value (@($subscriptionEvaluations).Count).ToString()
Write-StatusLine -Label "Matching subscriptions" -Value $subscriptionsWithMatchingBudgets.ToString()
Write-StatusLine -Label "Excluded subscriptions" -Value $excludedCount.ToString()
Write-StatusLine -Label "Budgets exceeded" -Value $budgetsExceeded.ToString()
Write-StatusLine -Label "Errors" -Value $errorCount.ToString()
if ($errorCount -gt 0) {
    foreach ($errorMessage in $errors) {
        Write-Warning $errorMessage
    }
}

Write-RunEvent -EventRecord $summary -LogPath $effectiveLogFile

