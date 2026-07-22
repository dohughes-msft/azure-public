# Azure Amortized Budget Monitor

Azure does not currently support setting budgets based on amortized spend, only actual spend. This project attempts to close that gap and provide a framework to monitor month-to-date amortized spend and compare it to user-defined budget rules.

* Works with MCA (not EA)
* Works with month-to-date spend (i.e. monthly budget)
* Works at subscription level
* Only alerts based on actual spend (not forecasted)

The script can be run in the following modes:
* `Local` (for testing)
  - For cost data either the Cost Management API or a local file (see `spend.sample.json`) can be used
  - For budget data either an Azure Table or a local file (see `budgets.sample.json`) can be used
  - For state data either an Azure Table or non-persistent memory can be used (i.e. no persistence between runs)
* `AzureAutomation`
  - For cost data the Cost Management API is used
  - For budget data an Azure Table is used
  - For state data an Azure Table or non-persistent memory can be used

Roles needed:
* If the [Cost Management API](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage) is used then the user or automation account must have role Billing Profile Reader
* If AzureTable storage is used for budgets and/or state then the user of automation account must have role Storage Table Data Contributor on the storage account

## Script flow

```
+------------------------------------+
| Start (Scripts/budget_monitor.ps1) |
+------------------------------------+
                 |
                 v
+-------------------------------------------+
| Resolve execution mode                    |
| - Local                                   |
| - AzureAutomation                         |
|   (forces SpendData=CostAPI,              |
|    BudgetData=AzureTable, stdout only)    |
+---------------------+---------------------+
                      |
                      v
+-------------------------------------------+
| Resolve data sources                      |
| - SpendData: File or CostAPI              |
| - BudgetData: File or AzureTable          |
+---------------------+---------------------+
                      |
      +---------------+---------------+
      |                               |
      v                               v
+---------------------------+   +---------------------------+
| Load spend input          |   | Load budget input         |
| - File: read SpendFile    |   | - File: read BudgetFile   |
| - CostAPI: query billing  |   | - AzureTable: read table  |
+-------------+-------------+   +-------------+-------------+
              |                               |
              +---------------+---------------+
                              |
                              v
    +---------------------------------------+
    | Build lookups and evaluate budgets    |
    | - iterate spend subscriptions         |
    | - match enabled budgets               |
    | - compute utilization and thresholds  |
    +------------------+--------------------+
                       |
                       v
    +---------------------------------------+
    | Alert + dedupe                        |
    | - highest newly-breached threshold    |
    | - persist dedupe state (Azure Table)  |
    +------------------+--------------------+
                       |
                       v
    +---------------------------------------+
    | Emit events + run summary             |
    | - Default: machine-style stdout events|
    | - Verbose: human progress/status lines|
    | - Local: optional log file append     |
    | - AzureAutomation: stdout only        |
    +---------------------------------------+
```

## How budget matching works

1. Fetch the amortized spend per subscription (from `SpendFile` or Cost API).
2. Iterate over the subscription IDs.
3. For each subscription ID, load matching enabled budget rows (from `BudgetFile` or Azure Table).
4. Compare subscription spend to each matched budget amount.
5. If spend is greater than or equal to budget amount, emit a warning and record the state (if Azure Table storage is in use) to avoid duplicating the alert again this month.

## Prerequisites

- PowerShell 7+
- Az PowerShell modules (at minimum `Az.Accounts`)
- `Billing Profile Reader` (if the Cost Management API is in use)
- Storage table data-plane role on the target storage account for the running identity:
  - `Storage Table Data Contributor` (minimum required for bootstrap, seed, and monitor table operations)

## Setup - Local

```powershell
cd projects/AmortizedBudget
```

Set required values in `Config/parameters.json`:

- `Config/parameters.json` is validated by `Config/parameters.schema.json`.
- The script performs runtime schema validation and fails fast on invalid config.

- `billing_account_id`
- `billing_profile_id`
- `state.storage_account` (if using AzureTable for state)
- `state.budget_table` (if using AzureTable for state)
- `state.alert_state_table` (if using AzureTable for state)

Bootstrap the Azure resources:

```powershell
./Scripts/bootstrap_resources.ps1 -ConfigFile ./Config/parameters.json -ResourceGroupName rg-amortized-budget -Location eastus -StorageAccountName stamortizedbudget001 -SubscriptionId 00000000-0000-0000-0000-000000000000
```

Before running bootstrap, ensure the caller has `Storage Table Data Contributor` on the storage account scope, otherwise table initialization will fail with `AuthorizationFailure`.

Seed your budget table from JSON:

```powershell
./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json
```

## Setup - Azure Automation

Use Azure Table Storage for both budget configuration and durable dedupe state when running from Azure Automation.

1. Enable system-assigned managed identity on the Automation Account.
2. Grant identity access to your Storage Account:
   - `Storage Table Data Contributor` on the storage account.
3. Pass required values as script parameters in the runbook invocation:
  - `-BillingAccountId`
  - `-BillingProfileId`
  - `-StorageAccount`
  - `-BudgetTable`
  - `-AlertStateTable`
  - Optional: `-PartitionPrefix`

Example:

```powershell
./Scripts/budget_monitor.ps1 -ExecutionMode AzureAutomation -SpendData CostAPI -BudgetData AzureTable -BillingAccountId <billing-account-id> -BillingProfileId <billing-profile-id> -StorageAccount <storage-account> -BudgetTable <budget-table> -AlertStateTable <alert-state-table>
```

The script will create both tables automatically if they do not exist.

Minimum Azure resources created by the bootstrap script:

- One resource group
- One StorageV2 storage account
- One budget configuration table
- One alert-state dedupe table

## Run

Local file run:

```powershell
./Scripts/budget_monitor.ps1 -SpendData File -BudgetData File -SpendFile ./LocalData/spend.sample.json -BudgetFile ./LocalData/budgets.sample.json
```

Azure Automation run:

```powershell
./Scripts/budget_monitor.ps1 -ExecutionMode AzureAutomation -SpendData CostAPI -BudgetData AzureTable -BillingAccountId <billing-account-id> -BillingProfileId <billing-profile-id> -StorageAccount <storage-account> -BudgetTable <budget-table> -AlertStateTable <alert-state-table>
```

Azure Automation mode ignores local config and file inputs and writes only to stdout.

Normal run:

```powershell
./Scripts/budget_monitor.ps1
```

Verbose run (adds human-readable progress lines):

```powershell
./Scripts/budget_monitor.ps1 -Verbose
```

Optional explicit log file:

```powershell
./Scripts/budget_monitor.ps1 -LogFile ./Logs/custom-run.log
```

Test with file data (no Azure API calls):

```powershell
./Scripts/budget_monitor.ps1 -SpendData File -BudgetData File -SpendFile ./LocalData/spend.sample.json -BudgetFile ./LocalData/budgets.sample.json
```

Export current month cost data to a JSON file (separate helper script):

```powershell
./Scripts/export_cost.ps1 -OutputFile ./Logs/cost-export.json
```

Or with a custom date range:

```powershell
./Scripts/export_cost.ps1 -StartDate 2026-06-01 -EndDate 2026-06-30 -OutputFile ./Logs/june-export.json
```

## Local test harness (no Azure calls)

Run the local dry-run helper to evaluate file inputs without Azure calls.

You can also pass `-SpendFile` and `-BudgetFile` directly to `budget_monitor.ps1` when `-SpendData File` and `-BudgetData File` are in use.

File formats:

- Spend file: JSON array where each entry includes `SubscriptionID`, `SubscriptionName`, and `PreTaxCostUSD`.
- Budgets file: JSON array where each entry includes `subscriptionId`, `budgetName`, `budgetAmount`, and `actualWarningThresholds` (plus optional `recipientEmail`, `enabled`).

## Azure Table schemas

Budget table (`state.budget_table`) row fields:

- `PartitionKey`: subscription ID
- `RowKey`: budget name
- `budgetAmount`: monthly budget amount
- `actualWarningThresholds`: comma-delimited string (for example `80,90,100`) or array in file input
- `recipientEmail`: recipient for alert context
- `enabled`: optional boolean, default `true`

Alert state table (`state.alert_state_table`) row fields (written by script):

- `PartitionKey`: `{partition_prefix}:{yyyy-MM}`
- `RowKey`: SHA-256 hash of dedupe key (`subscriptionId|budgetName|threshold|period`)
- `subscriptionId`, `subscriptionName`, `budgetName`, `budgetAmount`
- `thresholdPercent`, `utilizationPercent`, `subscriptionAmortizedSpend`
- `recipientEmail`, `deliveryStatus`, `deliveryDetail`
- `deliveryStatus`: `sent` (email delivered), `skipped` (no recipient), `failed` (send error), `suppressed` (lower threshold)

## Output

The monitor prints machine-style event lines by default:

- Job start event (`type=job_start`) with run ID and period
- Budget exceeded warning events (`type=budget_exceeded_warning`)
- Alert sent events (`type=alert_sent`, includes suppressed thresholds with `deliveryStatus=suppressed`)
- Alert already sent events (`type=alert_already_sent`, dedupe hit)
- One run summary (`type=run_summary`) including counts and diagnostics
- Human-readable progress and status lines are shown only when `-Verbose` is used
- Local runs append event lines to `./Logs/amortized-budget-monitor.log` (or `-LogFile` if provided)
- Azure Automation runs use standard output only (no local log file unless `-LogFile` is provided)

## Notes

- Spend query scope is billing profile:
  `/providers/Microsoft.Billing/billingAccounts/{billingAccountId}/billingProfiles/{billingProfileId}`
- Warnings are emitted when a matched budget is exceeded.
- Dedupe state is stored in Azure Table Storage using partition key `{partition_prefix}:{yyyy-MM}` and deterministic hashed row keys.

## Troubleshooting

### Authentication failures

- Symptom: access token request fails or Azure login errors.
- Check: run `Get-AzContext` and confirm the expected tenant/account.
- Fix: run `Connect-AzAccount` locally (or ensure Automation Account managed identity is configured correctly).

### Billing scope authorization errors

- Symptom: 401 or 403 when querying Cost Management.
- Check: identity has permissions at billing profile scope.
- Fix: grant billing scope cost read permissions and rerun.

### Storage table authorization failures

- Symptom: `AuthorizationFailure` from `table.core.windows.net` while creating or writing tables.
- Check: caller identity has storage table data-plane RBAC on the storage account.
- Fix: assign `Storage Table Data Contributor` at storage account scope, wait for RBAC propagation, and rerun.

### Missing budget matches

- Symptom: run summary shows zero `subscriptionsWithMatchingBudgets`.
- Check: enabled rows exist in the configured budget table for the subscriptions being evaluated.
- Fix: add or enable matching rows in the budget table.

### No warnings emitted

- Symptom: only run summary is printed.
- Check: matched budgets and budget amounts versus current amortized spend.
- Fix: confirm budget names match prefix and test with a subscription whose spend exceeds its budget amount.

### Duplicate alerts unexpectedly suppressed

- Symptom: thresholds crossed but no alert event emitted.
- Check: dedupe entity exists in `state.alert_state_table` for the current `{partition_prefix}:{yyyy-MM}` partition.
- Fix: delete the specific dedupe entity if you intentionally need to re-send the same alert in the same month.

## Budget Table Reference

This section defines the expected schema for the budget configuration table used by the amortized budget monitor.

### Table names

- Budget config table: `state.budget_table`
- Alert dedupe table: `state.alert_state_table`

### Budget table schema

Required entity keys:

- `PartitionKey`: subscription ID
- `RowKey`: budget name

Recommended fields:

- `budgetAmount` (number): monthly budget amount
- `actualWarningThresholds` (string): comma-delimited thresholds, for example `80,90,100`
- `recipientEmail` (string): recipient for alert context
- `enabled` (bool): optional, default `true`
- `lastUpdatedUtc` (string): ISO-8601 timestamp

### Alert state table schema

Written by the monitor script for dedupe tracking.

- `PartitionKey`: `{partition_prefix}:{yyyy-MM}`
- `RowKey`: SHA-256 hash of `subscriptionId|budgetName|threshold|period`
- `subscriptionId`, `subscriptionName`, `budgetName`, `budgetAmount`
- `thresholdPercent`, `utilizationPercent`, `subscriptionAmortizedSpend`
- `recipientEmail`, `deliveryStatus`, `deliveryDetail`
- `deliveryStatus`: `sent` (email delivered), `skipped` (no recipient), `failed` (send error), `suppressed` (lower threshold)

### Seed file format

Use JSON array rows like this:

```json
[
  {
    "subscriptionId": "4fc23711-7501-42c3-b531-8384e7ad6e2b",
    "budgetName": "Amortized-Prod",
    "budgetAmount": 3500,
    "actualWarningThresholds": [80, 90, 100],
    "recipientEmail": "finops-prod@contoso.com",
    "enabled": true
  },
  {
    "subscriptionId": "f5aa58b1-d08b-4e4e-8314-0a63ec271e6d",
    "budgetName": "Amortized-Dev",
    "budgetAmount": 800,
    "actualWarningThresholds": [80, 100],
    "recipientEmail": "finops-dev@contoso.com",
    "enabled": true
  }
]
```

### Seed with provided script

Create the Azure resources first:

Prerequisite: the identity running bootstrap/seed must have `Storage Table Data Contributor` on the target storage account scope.

```powershell
cd projects/AmortizedBudget
./Scripts/bootstrap_resources.ps1 -ConfigFile ./Config/parameters.json -ResourceGroupName rg-amortized-budget -Location eastus -StorageAccountName stamortizedbudget001 -SubscriptionId 00000000-0000-0000-0000-000000000000
```

```powershell
cd projects/AmortizedBudget
./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json
```

Dry run:

```powershell
./Scripts/seed_budget_table.ps1 -ConfigFile ./Config/parameters.json -BudgetFile ./LocalData/budgets.sample.json -DryRun
```

### Direct Azure CLI entity inserts

If you prefer direct inserts, one row example:

```powershell
az storage entity insert \
  --account-name <storage-account-name> \
  --table-name AmortizedBudgetConfig \
  --entity PartitionKey=4fc23711-7501-42c3-b531-8384e7ad6e2b RowKey=Amortized-Prod budgetAmount=3500 actualWarningThresholds=80,90,100 recipientEmail=finops-prod@contoso.com enabled=true
```

### Notes

- Keep `PartitionKey` equal to the subscription ID so lookups are cheap.
- Keep `RowKey` stable (budget name) to allow idempotent upserts.
- The monitor will ignore rows that do not parse to `budgetAmount > 0`.

