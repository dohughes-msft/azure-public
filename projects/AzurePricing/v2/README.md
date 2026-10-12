# Azure Pricing (v2)

Data pipeline for a Power BI report that shows Azure retail pricing by location. Two PowerShell scripts fetch data from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) and Azure resource metadata, producing JSON files that Power BI consumes as a data source.

## Scripts

| Script | Output | Description |
|---|---|---|
| `GetPricing.ps1` | `pricing_<region>.json` (one per region) | Fetches retail pricing data for all Azure regions |
| `GetLocations.ps1` | `locations.json` | Fetches Azure region names and display names for use as a lookup table |

## Architecture

```
GetLocations.ps1 ──► locations.json ──┐
                                      ├──► Power BI Report
GetPricing.ps1 ──► pricing_*.json ────┘
```

When running locally, JSON files are written to the current directory. When running in an Azure Automation account, files are uploaded to blob storage and Power BI connects to the storage account.

## Why per-region pricing files?

The API returns a very large dataset. Splitting by region keeps memory usage manageable, especially when running inside an Azure Automation account.

## Usage

### Local execution

```powershell
# Fetch location lookup data
.\GetLocations.ps1 -Verbose

# Fetch pricing for all regions
.\GetPricing.ps1 -Verbose

# Debug mode — single region (westeurope), single page only
.\GetPricing.ps1 -debugMode $true -Verbose
```

### Azure Automation account

```powershell
.\GetLocations.ps1 -automationAccount $true -storageAccountName "mystorageaccount" -containerName "locations"
.\GetPricing.ps1 -automationAccount $true -storageAccountName "mystorageaccount" -containerName "pricing"
```

The automation account must have:

- A **system-assigned managed identity**
- The **Storage Blob Data Contributor** role on the target storage account (Owner alone is not sufficient)

## Parameters

### GetPricing.ps1

| Parameter | Type | Default | Description |
|---|---|---|---|
| `automationAccount` | bool | `$false` | Run in Azure Automation mode and upload results to blob storage |
| `storageAccountName` | string | `azpricingstg2` | Storage account name (required when `automationAccount` is `$true`) |
| `containerName` | string | `pricing` | Blob container name (required when `automationAccount` is `$true`) |
| `debugMode` | bool | `$false` | Fetch only one region and one page of results for testing |

### GetLocations.ps1

| Parameter | Type | Default | Description |
|---|---|---|---|
| `automationAccount` | bool | `$false` | Run in Azure Automation mode and upload results to blob storage |
| `storageAccountName` | string | `azpricingstg2` | Storage account name (required when `automationAccount` is `$true`) |
| `containerName` | string | `locations` | Blob container name (required when `automationAccount` is `$true`) |

## Prerequisites

- PowerShell modules: **Az.Accounts**, **Az.Resources**, and **Az.Storage** (only needed for automation account mode)

## Features

- Automatic retry with exponential backoff on HTTP 429 (throttling)
- Progress bar showing region completion
- Pagination handling for large result sets
- Module availability check at startup
- Parameter validation for automation account mode
- Temp file cleanup after blob upload
