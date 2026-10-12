<#
.SYNOPSIS
Exports amortized cost data by subscription to a JSON file.

.DESCRIPTION
Queries Azure Cost Management at billing profile scope, aggregates PreTaxCostUSD by
subscription, and writes a JSON array to disk. The script reads billing identifiers from
the provided config file and uses Az PowerShell authentication via Get-AzAccessToken.

In this project, this script can be used to generate a local spend.json file for testing
the amortized budget monitor in local execution mode.

.PARAMETER ConfigFile
Path to the JSON configuration file that includes billing_account_id and billing_profile_id.

.PARAMETER OutputFile
Destination path for the exported JSON file. If an empty value is passed, the script creates
a timestamped file under the Logs folder.

.PARAMETER StartDate
Optional start date in a format PowerShell can parse (for example 2026-06-01).
Defaults to the first day of the current UTC month when omitted.

.PARAMETER EndDate
Optional end date in a format PowerShell can parse (for example 2026-06-30).
Defaults to the current UTC date when omitted.

.EXAMPLE
./Scripts/export_cost.ps1

Exports the current month-to-date amortized cost to the default output file.

.EXAMPLE
./Scripts/export_cost.ps1 -OutputFile ./Logs/cost-export.json

Exports the current month-to-date amortized cost to a custom file path.

.EXAMPLE
./Scripts/export_cost.ps1 -StartDate 2026-06-01 -EndDate 2026-06-30 -OutputFile ./Logs/june-cost-export.json

Exports amortized cost for a custom date range.

.NOTES
Requires Az.Accounts and an authenticated Azure context with permission to query 
Cost Management at billing profile scope.
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = "..\Config\parameters.json",
    [string]$OutputFile = "..\Logs\cost-api-export.json",
    [string]$StartDate = "",
    [string]$EndDate = ""
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

function Get-DefaultCostExportPath {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    return Join-Path -Path "Logs" -ChildPath ("cost-api-export-{0}.json" -f $stamp)
}

function Convert-CostDataToOutputRows {
    param($CostData)

    $spendBySubscription = Get-ObjectValue -Object $CostData -Name "spendBySubscription" -DefaultValue @{}
    $subscriptionNameById = Get-ObjectValue -Object $CostData -Name "subscriptionNameById" -DefaultValue @{}

    $outputRows = foreach ($subscriptionId in @($spendBySubscription.Keys | Sort-Object)) {
        $subscriptionName = ""
        if ($subscriptionNameById.ContainsKey($subscriptionId)) {
            $subscriptionName = [string]$subscriptionNameById[$subscriptionId]
        }

        [PSCustomObject]@{
            SubscriptionID = [string]$subscriptionId
            SubscriptionName = $subscriptionName
            PreTaxCostUSD = [Math]::Round([double]$spendBySubscription[$subscriptionId], 2)
        }
    }

    return @($outputRows)
}

function Export-CostDataToFile {
    param(
        $CostData,
        [string]$Path
    )

    $effectiveOutputPath = $Path
    if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
        $effectiveOutputPath = Get-DefaultCostExportPath
    }

    $parent = Split-Path -Path $effectiveOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $outputRows = Convert-CostDataToOutputRows -CostData $CostData
    $outputRows | ConvertTo-Json -Depth 10 | Set-Content -Path $effectiveOutputPath -Encoding UTF8

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "Export Complete" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ("{0,-24}: {1}" -f "Status", "success")
    Write-Host ("{0,-24}: {1}" -f "File", [string](Resolve-Path -Path $effectiveOutputPath))
    Write-Host ("{0,-24}: {1}" -f "Rows exported", @($outputRows).Count.ToString())
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
    Write-Host "Requesting Cost Management data..." -ForegroundColor Cyan
    $page = Invoke-RestWithRetry -Method "POST" -Uri $uri -Headers $headers -Body $body -MaxRetries 6 -BackoffSeconds 1.5 -TimeoutSeconds 30
    $pages += $page
    $firstRowCount = @($page.properties.rows).Count
    Write-Host ("  Page 1: retrieved {0} grouped cost rows" -f $firstRowCount) -ForegroundColor Green

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
        Write-Host ("  Page {0}: retrieved {1} grouped cost rows" -f $pageNumber, @($page.properties.rows).Count) -ForegroundColor Green
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

# ===== Main Script =====

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

$billingAccountId = [string](Get-ConfigValue -Map $fileConfig -Key "billing_account_id" -DefaultValue "")
$billingProfileId = [string](Get-ConfigValue -Map $fileConfig -Key "billing_profile_id" -DefaultValue "")

if ([string]::IsNullOrWhiteSpace($billingAccountId) -or [string]::IsNullOrWhiteSpace($billingProfileId)) {
    throw "BILLING_ACCOUNT_ID and BILLING_PROFILE_ID are required in configuration."
}

# Parse dates
$today = (Get-Date).ToUniversalTime().Date
$periodStart = $today.AddDays(-($today.Day - 1))
$periodEnd = $today.AddDays(-1)

if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
    try {
        $periodStart = [datetime]::ParseExact($StartDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    }
    catch {
        throw "Invalid StartDate format. Use yyyy-MM-dd."
    }
}

if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
    try {
        $periodEnd = [datetime]::ParseExact($EndDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    }
    catch {
        throw "Invalid EndDate format. Use yyyy-MM-dd."
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Export Cost Data to JSON" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ("{0,-24}: {1}" -f "Billing account", $billingAccountId)
Write-Host ("{0,-24}: {1}" -f "Billing profile", $billingProfileId)
Write-Host ("{0,-24}: {1}" -f "Period start", $periodStart.ToString("yyyy-MM-dd"))
Write-Host ("{0,-24}: {1}" -f "Period end", $periodEnd.ToString("yyyy-MM-dd"))
Write-Host ("{0,-24}: {1}" -f "Output file", $(if ([string]::IsNullOrWhiteSpace($OutputFile)) { "(auto-generated in ./Logs)" } else { $OutputFile }))

$token = Get-AccessToken -Resource "https://management.azure.com/"
$costData = Get-AmortizedSpendBySubscription -Token $token -BillingAccountId $billingAccountId -BillingProfileId $billingProfileId -PeriodStart $periodStart -PeriodEnd $periodEnd
Export-CostDataToFile -CostData $costData -Path $OutputFile
