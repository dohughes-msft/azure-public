<#
.SYNOPSIS
Bootstraps Azure resources required by the AmortizedBudget workflow.

.DESCRIPTION
Creates or confirms the target resource group and storage account, then ensures the
configured budget and alert-state Azure Table Storage tables exist. The script reads
table names from the config file and authenticates with Az PowerShell.

.PARAMETER ConfigFile
Path to the configuration file that contains the state section with table names.

.PARAMETER ResourceGroupName
Name of the Azure resource group to create or reuse.

.PARAMETER Location
Azure region for the resource group and storage account, such as eastus.

.PARAMETER StorageAccountName
Storage account name to create or reuse. Must be 3-24 lowercase letters or numbers.

.PARAMETER SubscriptionId
Azure subscription ID to target for bootstrap operations.

.PARAMETER DryRun
Shows the actions that would be performed without creating or updating resources.

.EXAMPLE
./Scripts/bootstrap_resources.ps1 -ConfigFile ./Config/parameters.json -ResourceGroupName rg-amortized-budget -Location eastus -StorageAccountName stamortizedbudget001 -SubscriptionId 00000000-0000-0000-0000-000000000000

Bootstraps the resource group, storage account, and required tables.

.EXAMPLE
./Scripts/bootstrap_resources.ps1 -ConfigFile ./Config/parameters.json -ResourceGroupName rg-amortized-budget -Location eastus -StorageAccountName stamortizedbudget001 -SubscriptionId 00000000-0000-0000-0000-000000000000 -DryRun

Prints planned bootstrap actions without modifying Azure resources.

.NOTES
Requires Az modules including Az.Accounts and an authenticated context with permission
to create or read resource groups, storage accounts, and storage table data-plane objects.
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = "..\Config\parameters.json",
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory)]
    [string]$Location,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountName,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,
    [switch]$DryRun
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
    param([string]$Resource)

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

            $statusCode = Get-HttpStatusCode -ErrorRecord $_
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
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($statusCode -eq 403) {
            throw "AuthorizationFailure while creating table '$TableName' in storage account '$StorageAccount'. Grant the caller a Storage Table data-plane role (for example 'Storage Table Data Contributor') on the storage account and retry."
        }

        if ($statusCode -ne 409) {
            throw
        }
    }
}

function Get-NormalizedStorageAccountName {
    param(
        [string]$RequestedName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedName)) {
        $normalized = $RequestedName.ToLowerInvariant()
    }
    else {
        $seed = "{0}{1}" -f $ResourceGroupName.ToLowerInvariant(), $SubscriptionId.ToLowerInvariant()
        $sanitized = ($seed -replace '[^a-z0-9]', '')
        if ($sanitized.Length -lt 12) {
            $sanitized = ($sanitized + "amortizedbudgetbootstrap")
        }

        $prefix = $sanitized.Substring(0, [Math]::Min(16, $sanitized.Length))
        $hashInput = [System.Text.Encoding]::UTF8.GetBytes($seed)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = -join ($sha256.ComputeHash($hashInput) | ForEach-Object { $_.ToString("x2") })
        }
        finally {
            $sha256.Dispose()
        }

        $normalized = ($prefix + $hash.Substring(0, 8))
    }

    if ($normalized.Length -gt 24) {
        $normalized = $normalized.Substring(0, 24)
    }

    if ($normalized -notmatch '^[a-z0-9]{3,24}$') {
        throw "Storage account name '$normalized' is invalid. Use 3-24 lowercase letters or numbers."
    }

    return $normalized
}

function Test-AzCommandAvailable {
    param([string]$CommandName)

    return ($null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue))
}

$requiredCommands = @(
    "Get-AzContext",
    "Get-AzResourceGroup",
    "New-AzResourceGroup",
    "Get-AzStorageAccount",
    "New-AzStorageAccount"
)

foreach ($commandName in $requiredCommands) {
    if (-not (Test-AzCommandAvailable -CommandName $commandName)) {
        throw "$commandName is not available. Install/import the required Az module and retry."
    }
}

$config = Import-JsonFile -Path $ConfigFile
$stateConfig = Get-ConfigValue -Map $config -Key "state" -DefaultValue @{}

$budgetTableName = [string](Get-ConfigValue -Map $stateConfig -Key "budget_table" -DefaultValue "AmortizedBudgetConfig")
$alertStateTableName = [string](Get-ConfigValue -Map $stateConfig -Key "alert_state_table" -DefaultValue "AmortizedBudgetAlertState")

$context = Get-AzContext
if ($null -eq $context) {
    throw "No Azure context found. Run Connect-AzAccount and retry."
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    if ($DryRun) {
        Write-Host ("[DryRun] Would switch to subscription: {0}" -f $SubscriptionId) -ForegroundColor Yellow
    }
    else {
        Set-AzContext -Subscription $SubscriptionId | Out-Null
        $context = Get-AzContext
    }
}

$effectiveSubscriptionId = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { [string]$context.Subscription.Id } else { $SubscriptionId }
$effectiveStorageAccountName = Get-NormalizedStorageAccountName -RequestedName $StorageAccountName -ResourceGroupName $ResourceGroupName -SubscriptionId $effectiveSubscriptionId

Write-Host "Azure resource bootstrap" -ForegroundColor Cyan
Write-Host ("Config file       : {0}" -f $ConfigFile)
Write-Host ("Subscription      : {0}" -f $effectiveSubscriptionId)
Write-Host ("Resource group    : {0}" -f $ResourceGroupName)
Write-Host ("Location          : {0}" -f $Location)
Write-Host ("Storage account   : {0}" -f $effectiveStorageAccountName)
Write-Host ("Budget table      : {0}" -f $budgetTableName)
Write-Host ("Alert state table : {0}" -f $alertStateTableName)
Write-Host ("Dry run           : {0}" -f $DryRun.ToString())

if ($DryRun) {
    Write-Host ("[DryRun] Would create or confirm resource group '{0}' in '{1}'" -f $ResourceGroupName, $Location) -ForegroundColor Yellow
    Write-Host ("[DryRun] Would create or confirm storage account '{0}'" -f $effectiveStorageAccountName) -ForegroundColor Yellow
    Write-Host ("[DryRun] Would ensure tables '{0}' and '{1}' exist" -f $budgetTableName, $alertStateTableName) -ForegroundColor Yellow
}
else {
    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $resourceGroup) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    }

    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $effectiveStorageAccountName -ErrorAction SilentlyContinue
    if ($null -eq $storageAccount) {
        $tags = @{ project = "AmortizedBudget"; managedBy = "bootstrap_resources.ps1" }
        $storageAccount = New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $effectiveStorageAccountName -Location $Location -SkuName Standard_LRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 -EnableHttpsTrafficOnly $true -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -Tag $tags
    }

    $storageToken = Get-AccessToken -Resource "https://storage.azure.com/"
    Initialize-Table -Token $storageToken -StorageAccount $effectiveStorageAccountName -TableName $budgetTableName
    Initialize-Table -Token $storageToken -StorageAccount $effectiveStorageAccountName -TableName $alertStateTableName
}

Write-Host ""
Write-Host "Bootstrap complete" -ForegroundColor Cyan
Write-Host ("Storage account   : {0}" -f $effectiveStorageAccountName)
Write-Host ("Budget table      : {0}" -f $budgetTableName)
Write-Host ("Alert state table : {0}" -f $alertStateTableName)
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Ensure your identity has billing-scope read access for Cost Management."
Write-Host ("2. Seed budget rows with ./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json")
Write-Host ("3. Run the monitor with ./Scripts/budget_monitor.ps1")
