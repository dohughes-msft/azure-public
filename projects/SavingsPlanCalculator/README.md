# Savings Plan Calculator Toolset

This toolset is designed to help Azure customers model the purchase of different amounts of Azure Savings Plan for Compute, based on past Azure spend. It consists of:

1. PowerShell scripts to collect cost data from Microsoft Cost Management APIs.
2. An Excel document to import the data and perform the modeling.

## Azure roles needed

Preferred:
- EA: Enrollment reader (aka EA admin read only) on the billing account
- MCA: Billing profile reader

These roles allow visibility of all cost management information and are required if you plan to purchase savings plans at the top-level scope.

Sufficient:
- Cost Management Reader on a management group, subscription, or resource group

These roles allow partial visibility of cost management information and are sufficient if you plan to purchase savings plans at these lower-level scopes.

## Step 1: Data Collection

There is sample data supplied with the toolset. If you wish, you can skip this step and go directly to Step 2 to practice modeling with sample data.

Data Collection is performed via PowerShell scripts that invoke the [Microsoft Cost Management Query API](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage). Before running them you need to be logged in to PowerShell as a user with the appropriate roles above. PowerShell 7+ is recommended.

### Set the scope in the parameter file

In directory `Config` copy file `parameters.sample.json` to `parameters.json`.

The file contains a single parameter that should be set according to the the desired scope. The example uses billing account:

```
{
    "Scope": "/providers/Microsoft.Billing/billingAccounts/123123123"
}
```

For other supported scope types see the [API Documentation](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage#uri-parameters).

### Log in to Azure

1. Install the required `Az.Accounts` PowerShell module, if not present:

`Install-Module Az.Accounts -Scope CurrentUser`

2. Connect to Azure:

`Connect-AzAccount`

### Execute the scripts

`cd Scripts`

There are two scripts to execute. They can be run in any order.

| Script name | Purpose | Syntax | Output file |
| ----------- | ------- | ------ | ----------- |
| `Get-SpendByPricingModel.ps1` | Fetches monthly VM spend grouped by pricing model | `.\Get-SpendByPricingModel -parameterFile "..\Config\parameters.json"` | `DataCollection\SpendByPricingModel.csv` |
| `Get-SpendByVMFamily.ps1` | Last month's PAYG VM spend grouped by meter subcategory | `.\GetSpendByVMFamily.ps1 -parameterFile "..\Config\parameters.json"` | `DataCollection\SpendByVMFamily.csv` |

Both scripts:
- Use Cost Management query API version 2025-03-01 by default.
- Resolve scope from a JSON parameter file.
- Automatically create outputDir if it does not exist.

### Output

By default, CSVs are written to DataCollection:

- `DataCollection/SpendByPricingModel.csv`
- `DataCollection/SpendByVMFamily.csv`

## Step 2: Modeling

1. Check that the two CSV files are present and contain data.
2. Note the absolute path to the folder containing your newly-generated CSV files.
3. Open the Excel document and follow the instructions in tab `Instructions`.

## Script Parameters Reference

Shared parameters:

- parametersFile
  - Default: Config\parameters.json
- months
  - Pricing model script default: 6
  - VM family script default: 1
  - Window is full prior months only (from first day of month N months ago through last day of previous month).
- outputDir
  - Default: DataCollection
- outputFile
  - Pricing model default: SpendByPricingModel.csv
  - VM family default: SpendByVMFamily.csv
- apiVersion
  - Default: 2025-03-01

## Troubleshooting

- Parameters file not found
  - Verify the path passed to -parametersFile.

- BillingAccountId required
  - Ensure Scope is BillingAccount and BillingAccountId is set.

- Authorization or 403 errors
  - Confirm your identity has Cost Management access at the billing account scope.

- Throttling (429) or transient API errors
  - Scripts already retry with backoff; rerun if needed.
