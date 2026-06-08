<#
.SYNOPSIS
    Query Azure Cost Management (amortized view) for the last N months at
    monthly granularity, grouped by publisher / charge / service / meter
    dimensions.

.DESCRIPTION
    Calls the Cost Management query REST API with type=AmortizedCost,
    granularity=Monthly, and emits a flat table with columns:

        UsageDate, ServiceName, MeterCategory, ServiceTier,
        MeterSubCategory, Cost, Currency

    Scope is read directly from the parameters JSON file. Provide the full
    Cost Management scope path in `Scope` (for example,
    /providers/Microsoft.Billing/billingAccounts/{billingAccountId}).

.PARAMETER parameterFile
    JSON file describing the cost-management scope. Default: Config\parameters.json.

.PARAMETER months
    Number of full prior months to include (default 6).

.PARAMETER outputFile
    Output CSV path. Default: DataCollection\SpendByVMFamily.csv.

.PARAMETER apiVersion
    Cost Management REST API version.

.EXAMPLE
    .\cost_query_daily_meter.ps1
    .\cost_query_daily_meter.ps1 -months 3 -outputFile .\daily.csv
#>

param (
    [string]$parameterFile = "..\Config\parameters.json",
    [int]$months            = 1,
    [string]$outputDir      = "..\DataCollection",
    [string]$outputFile     = "SpendByVMFamily.csv",
    [string]$apiVersion     = "2025-03-01"
)

$ErrorActionPreference = "Stop"

function Convert-ToAzRestPath {
    param([Parameter(Mandatory)][string]$UriOrPath)
    if ($UriOrPath -match "^https?://") {
        $u = [System.Uri]$UriOrPath
        return "$($u.AbsolutePath)$($u.Query)"
    }
    return $UriOrPath
}

function Get-RetryAfterSeconds {
    param($Response)
    if (-not $Response -or -not $Response.Headers) { return $null }
    $values = $null
    try {
        if ($Response.Headers -is [System.Collections.IDictionary]) {
            foreach ($k in $Response.Headers.Keys) {
                if ($k -and $k.ToString().Equals('Retry-After',[System.StringComparison]::OrdinalIgnoreCase)) {
                    $values = $Response.Headers[$k]; break
                }
            }
        } else {
            $hdr = $Response.Headers | Where-Object { $_.Key -and $_.Key.ToString().Equals('Retry-After',[System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
            if ($hdr) { $values = $hdr.Value }
        }
    } catch { return $null }
    if ($null -eq $values) { return $null }
    $first = if ($values -is [System.Collections.IEnumerable] -and -not ($values -is [string])) { @($values)[0] } else { $values }
    $s = "$first".Trim()
    if ($s -match '^\d+$') { return [int]$s }
    try {
        $when = [datetime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $delta = [int]([math]::Ceiling(($when - [datetime]::UtcNow).TotalSeconds))
        if ($delta -gt 0) { return $delta }
        return 1
    } catch { return $null }
}

function Invoke-RestWithRetry {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$UriOrPath,
        [string]$Body,
        [int]$MaxRetries     = 8,
        [int]$MaxBackoffSecs = 120
    )

    $attempt = 0
    while ($true) {
        $attempt++
        $response   = $null
        $statusCode = $null
        $errMessage = $null
        try {
            $path = Convert-ToAzRestPath -UriOrPath $UriOrPath
            $response = if ($Body) {
                Invoke-AzRestMethod -Method $Method -Path $path -Payload $Body
            } else {
                Invoke-AzRestMethod -Method $Method -Path $path
            }
            $statusCode = [int]$response.StatusCode
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
                return ($response.Content | ConvertFrom-Json -Depth 100)
            }
            $errMessage = "HTTP $statusCode for $Method $path : $($response.Content)"
        }
        catch {
            $errMessage = $_.Exception.Message
            $m = [regex]::Match($errMessage, '\b([1-5][0-9]{2})\b')
            if ($m.Success) { $statusCode = [int]$m.Groups[1].Value }
        }

        $retryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600) -or (-not $statusCode)
        if (-not $retryable -or $attempt -ge $MaxRetries) {
            throw $errMessage
        }

        $retryAfter = Get-RetryAfterSeconds -Response $response
        if ($retryAfter) {
            $delay = [math]::Min([int]$retryAfter, $MaxBackoffSecs)
        } else {
            $delay = [math]::Min([int][math]::Pow(2, $attempt), $MaxBackoffSecs)
        }
        Write-Warning ("Attempt {0} failed (status={1}). Retrying in {2}s..." -f $attempt, ($statusCode ?? 'n/a'), $delay)
        Start-Sleep -Seconds $delay
    }
}

function Format-UsageDate {
    # Cost Management returns UsageDate as YYYYMMDD (int) for Daily granularity.
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = "$Value"
    if ($s -match '^\d{8}$') { return "$($s.Substring(0,4))-$($s.Substring(4,2))-$($s.Substring(6,2))" }
    try { return ([datetime]$s).ToString('yyyy-MM-dd') } catch { return $s }
}

if (-not (Test-Path $parameterFile)) {
    throw "Parameters file not found: $parameterFile"
}
$parameters = Get-Content -Path $parameterFile -Raw | ConvertFrom-Json
$scope      = [string]$parameters.Scope
if ([string]::IsNullOrWhiteSpace($scope)) {
    throw "Scope is required in $parameterFile"
}

if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$outputPath = if ([System.IO.Path]::IsPathRooted($outputFile)) {
    $outputFile
} else {
    Join-Path -Path $outputDir -ChildPath $outputFile
}

$today     = Get-Date
$startDate = $today.AddMonths(-$months).ToString('yyyy-MM-01')
$endDate   = $today.AddDays(-1 * $today.Day).ToString('yyyy-MM-dd')

$requestBody = @{
    type       = "AmortizedCost"
    timeframe  = "Custom"
    timePeriod = @{
        from = "${startDate}T00:00:00Z"
        to   = "${endDate}T23:59:59Z"
    }
    dataset = @{
        granularity = "Monthly"
        aggregation = @{
            PreTaxCost = @{ name = "PreTaxCost"; function = "Sum" }
        }
        grouping = @(
            @{ type = "Dimension"; name = "MeterCategory"   },
            @{ type = "Dimension"; name = "MeterSubCategory"}
        )
        filter = @{
            and = @(
                @{ dimensions = @{ name = "ServiceName";   operator = "In"; values = @("Virtual Machines") } },
                @{ dimensions = @{ name = "PublisherType"; operator = "In"; values = @("Azure", "Microsoft") } },
                @{ dimensions = @{ name = "ChargeType";    operator = "In"; values = @("Usage") } },
                @{ dimensions = @{ name = "PricingModel";  operator = "In"; values = @("OnDemand") } }
            )
        }
    }
} | ConvertTo-Json -Depth 20

$uri = "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=$apiVersion"

Write-Output "Scope     : $scope"
Write-Output "Window    : $startDate -> $endDate (amortized, monthly)"

$pages    = @()
$pageNo   = 1
Write-Output "Requesting page $pageNo..."
$page     = Invoke-RestWithRetry -Method POST -UriOrPath $uri -Body $requestBody
$pages   += $page
$nextLink = $page.properties.nextLink

while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
    $pageNo++
    Write-Output "Requesting page $pageNo..."
    try {
        $page = Invoke-RestWithRetry -Method GET -UriOrPath $nextLink
    } catch {
        $page = Invoke-RestWithRetry -Method POST -UriOrPath $nextLink -Body $requestBody
    }
    $pages   += $page
    $nextLink = $page.properties.nextLink
}

$rows = foreach ($p in $pages) {
    if (-not $p.properties -or -not $p.properties.rows) { continue }
    $cols = @($p.properties.columns)

    foreach ($r in $p.properties.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $o[$cols[$i].name] = $r[$i]
        }
        [PSCustomObject]$o
    }
}

$rows | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
$rows | Format-Table -AutoSize

Write-Output ""
Write-Output "$($rows.Count) rows written to $outputPath"
