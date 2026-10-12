[CmdletBinding()]
param(
    [string]$ConfigFile = "Config/parameters.json",
    [string]$SpendFile = "LocalData/spend.json",
    [string]$BudgetFile = "LocalData/budgets.json",
    [ValidateSet("Memory", "AzureTable")]
    [string]$StateData = "Memory",
    [string]$LogFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$projectRoot = Split-Path -Parent $scriptRoot

function Resolve-ProjectPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $projectRoot -ChildPath $Path))
}

$resolvedConfig = Resolve-ProjectPath -Path $ConfigFile
$resolvedSpendFile = Resolve-ProjectPath -Path $SpendFile
$resolvedBudgetFile = Resolve-ProjectPath -Path $BudgetFile
$resolvedLogFile = ""
if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
    $resolvedLogFile = Resolve-ProjectPath -Path $LogFile
}

Write-Output "Running local file dry run for amortized budget monitor..."
Write-Output "Config: $resolvedConfig"
Write-Output "Spend file: $resolvedSpendFile"
Write-Output "Budget file: $resolvedBudgetFile"
Write-Output "State data: $StateData"

if ([string]::IsNullOrWhiteSpace($resolvedLogFile)) {
    Write-Output "Log file: auto (timestamped log in ./Logs for local runs)"
}
else {
    Write-Output "Log file: $resolvedLogFile"
}

$budgetMonitor = Join-Path -Path $scriptRoot -ChildPath "budget_monitor.ps1"

if ([string]::IsNullOrWhiteSpace($resolvedLogFile)) {
    pwsh -NoProfile -File $budgetMonitor -ExecutionMode Local -ConfigFile $resolvedConfig -SpendData File -BudgetData File -StateData $StateData -SpendFile $resolvedSpendFile -BudgetFile $resolvedBudgetFile
}
else {
    pwsh -NoProfile -File $budgetMonitor -ExecutionMode Local -ConfigFile $resolvedConfig -SpendData File -BudgetData File -StateData $StateData -SpendFile $resolvedSpendFile -BudgetFile $resolvedBudgetFile -LogFile $resolvedLogFile
}

