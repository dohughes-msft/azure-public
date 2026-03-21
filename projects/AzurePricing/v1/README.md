# Azure Pricing (v1)

Data pipeline for a Power BI report that shows Azure retail pricing by location. The PowerShell script is designed to run as a runbook in an **Azure Automation Account** on a schedule, fetching data from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) and uploading the resulting JSON files to blob storage. Power BI then connects to the storage account to consume the data. The script can also be run locally for testing.

## Files

| File | Description |
|---|---|
| `FetchPricing.ps1` | Fetches retail pricing data for all Azure regions, one JSON file per region |
| `Azure Pricing and Service Availability.pbit` | Power BI template that consumes the pricing JSON files. Requires the `StorageAccountName` parameter to be set when opening. |

## Architecture

```
┌─────────────────────────────────┐
│   Azure Automation Account      │
│                                 │
│  ┌───────────────────────────┐  │       ┌────────────────────────┐       ┌────────────────┐
│  │  FetchPricing.ps1         │──┼──────►│  Blob Storage          │──────►│  Power BI      │
│  │  (Scheduled Runbook)      │  │       │  Container: pricing    │       │  Report        │
│  └───────────┬───────────────┘  │       │  pricing_<region>.json │       └────────────────┘
│              │                  │       └────────────────────────┘
│              │                  │
│              ▼                  │
│  Azure Retail Prices API        │
│  (prices.azure.com)             │
└─────────────────────────────────┘
```

The automation account authenticates using a **system-assigned managed identity** and uploads one JSON file per region (`pricing_<region>.json`) to a blob container called `pricing`. Power BI connects to the storage account to refresh the report.

## Why per-region files?

The API returns a very large dataset. Splitting by region keeps memory usage manageable within the Azure Automation sandbox memory limit.

## Usage

### Azure Automation account (primary)

Import `FetchPricing.ps1` as a runbook and schedule it to run periodically. Set the parameters:

```powershell
.\FetchPricing.ps1 -automationAccount $true
```

The storage account name is passed as a parameter. The blob container name is hard-coded to `pricing`. The automation account must have:

- A **system-assigned managed identity**
- The **Storage Blob Data Contributor** role on the target storage account (Owner alone is not sufficient)

### Local execution (for testing)

```powershell
# Fetch pricing for all regions
.\FetchPricing.ps1 -Verbose

# Debug mode — single region (westeurope), single page only
.\FetchPricing.ps1 -debugMode $true -Verbose
```

Output files are written to the current directory as `pricing_<region>.json`.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `automationAccount` | bool | `$false` | Run in Azure Automation mode and upload results to blob storage |
| `debugMode` | bool | `$false` | Fetch only one region and one page of results for testing |

## Requirements

### Azure resources

- **Azure Automation Account** — to run the script as a scheduled runbook
  - System-assigned **managed identity** enabled
  - PowerShell modules imported: `Az.Accounts`, `Az.Resources`, `Az.Storage`
- **Azure Storage Account** — to hold the output JSON files
  - A **blob container** named `pricing`
  - The automation account's managed identity must have the **Storage Blob Data Contributor** role (Owner alone is not sufficient)

### Local tools (for testing only)

- **PowerShell 5.1+** or **PowerShell 7+**
- PowerShell modules: `Az.Accounts`, `Az.Resources`

### Reporting

- **Power BI Desktop** — to open the `.pbit` template and connect it to the JSON files in blob storage
- When opening the template, set the **`StorageAccountName`** parameter to the name of your storage account
- The user opening the report must have at least the **Storage Blob Data Reader** role on the storage account in order to retrieve data
