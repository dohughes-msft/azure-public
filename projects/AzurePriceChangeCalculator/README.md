# Azure Price Change Calculator

## Background

Microsoft has announced several changes to Azure pricing that are scheduled to take effect on February 1st 2027. This project aims to give customers an accurate way to calculate the impact.

**Ways to use this project**

1. The main intention is that you bring your own usage data and use the Power BI template to calculate the effects of the price increases. Or,
2. You can just take the billing meter ID data to lift into your own reports, and ignore the other components.

**Most report users only need to place their usage export in the appropriate folder, open the report, and refresh it.** PowerShell, Python, and Excel are not required.

**Note:** Customers with Enterprise Agreement (EA): Note that your EA may include price protection during the life of the agreement. This report does not take into account price protection.

## Disclaimers

1. This report is *NOT* an official Microsoft tool. The list of affected meter IDs is my own best effort to map what has been communicated officially with our billing data. It is an estimate only and will not be 100% correct. I repeat, this is not an official Microsoft product and all support is on a best effort basis by myself.
2. The estimate excludes reservations entirely. If you have reservations that expire between now and February 1st, and do not renew them, then the estimate will be too low.
3. If you are using Savings Plans, then the estimate should be considered the minimum price increase expected. When the changes kick in, your fixed hourly commitment will cover less consumption, meaning that some consumption previously covered by savings plan will become PAYG, with the resulting loss of savings plan discount.

### I. Pricing changes due to VM retirement

Prices for the following VM series will increase beginning 1 February 2027:

| Version | VM series | Price increase |
|---|---|---|
| v1 | Bv1, D, Ds, F, Fs, G, Gs, Ls, NP, and HC | 25% |
| v2 | Av2, Amv2, Dv2, Dsv2, Fsv2, and Lsv2 | 25% |

### II. Pricing changes due to region constraints

Beginning 1 February 2027, pricing will increase for specific Azure Virtual Machines and Azure Storage services in the following Azure regions:

| Region | Price increase |
|---|---|
| EU West (Amsterdam) | 9% |
| EU North (Dublin) | 17% |
| France Central | 11% |
| France South | 11% |
| Norway East | 9% |
| Norway West | 9% |
| Southeast Asia (Singapore) | 8% |

Resources affected by the first change are excluded from the second.

## Prerequisites

- Power BI Desktop.
- One or more amortized usage details CSV export files for the period to be analyzed. Do not combine files from multiple periods. Typically the last full month is the best place to start. You can process multiple MCA billing profiles or multiple EA billing accounts together.
- The supplied `MasterData\ComputeMeters.parquet` and `MasterData\StorageMeters.parquet` files. These have been prepared on a best-effort basis. If you want to create these yourself, see [here](MASTER-DATA.md).
- The `Azure Price Change Calculator.pbit` Power BI template supplied with this project.

Keep the template, master data, and usage folders together:

```text
AzurePriceChangeCalculator/
|-- Azure Price Change Calculator.pbit
|-- BillingMeterPreparation (see separate documentation)
|-- MasterData/
|   |-- ComputeMeters.parquet
|   `-- StorageMeters.parquet
|-- UsageFiles-EA/
`-- UsageFiles-MCA/
```

## 1. Download the project files

1. Download the [repository as a ZIP file](https://github.com/dohughes-msft/azure-public/archive/refs/heads/master.zip).
2. Extract the ZIP file.
3. Locate `azure-public-master\projects\AzurePriceChangeCalculator`.
4. Copy the entire `AzurePriceChangeCalculator` folder to a local working location, preserving its folder structure.

Keep the Power BI template, `MasterData`, and usage folders together. Do not download or move the individual files separately, because the report relies on their relative locations.

## 2. Place the amortized usage files in the appropriate folder

In Azure Cost Management, download usage details at the appropriate billing scope for the required period, selecting the **amortized cost** dataset rather than actual cost. See [Download Azure usage details](https://learn.microsoft.com/azure/cost-management-billing/understand/download-azure-daily-usage).

You can include exports for multiple MCA billing profiles or multiple EA billing accounts.

Place each CSV export in the folder matching the agreement type:

| Agreement | Destination relative to the project directory |
|---|---|
| Enterprise Agreement (EA) | `UsageFiles-EA\` |
| Microsoft Customer Agreement (MCA) | `UsageFiles-MCA\` |

Do not mix EA and MCA exports in the same folder, as their schemas differ.

**Usage files contain sensitive billing and resource information.** Handle them according to company data-handling requirements. Do not commit usage exports or populated Power BI reports to source control.

## 3. Start Power BI and refresh

1. Open the supplied `Azure Price Change Calculator.pbit` template in Power BI Desktop to create a report.
2. Configure the absolute path to the project folder when prompted.
3. Select **Load** to load the usage data.
4. Review the report and save the PBIX file locally in an approved location.

The supplied PBIT template provides the data-loading and pricing-change model. You do not normally need to create new queries, joins, or calculations.

If you are only using one type of data (EA or MCA), you will get a warning message saying some data can not be loaded. This can be safely ignored.

## 4. Check the results

Before sharing the report:

- Confirm that the loaded usage covers the intended period.
- If multiple scopes were loaded, confirm that they are multiple MCA billing profiles or multiple EA billing accounts.
- Reconcile the report's base amortized cost with the source exports for the same scope.
- Confirm that no overlapping exports were imported.
- Review any unmatched billing meters; a missing mapping is not confirmation of zero uplift.
- Confirm that the supplied master data reflects the pricing-change rules you intend to analyze.

## Refresh with new usage

Replace the prior export or add a non-overlapping period in the appropriate usage folder, then refresh Power BI. You do not need to rebuild the master data unless Microsoft publishes changes to the list of affected billing meters.

## Troubleshooting

### A file or folder cannot be found

Confirm the usage folder and both Parquet files exist, then update the report's local source paths in Power Query. Paths saved on the report author's machine may not match yours.

### Usage does not load or columns are missing

Check that the CSV is an amortized usage export in the expected EA or MCA format and is in the correct folder. Do not rename its headers.

### Cost totals are too high

Check for duplicate or overlapping exports. Also confirm that every export belongs to the single customer being analyzed; never combine exports from different customers. Multiple MCA billing profiles or multiple EA billing accounts are supported only when they belong to that customer.

### Billing meters have no uplift mapping

Ask the master-data maintainer to review the unmatched meters against the pricing snapshot and scope. The master data covers Compute Virtual Machines and Storage, not every Azure service.

## Optional: create or update master data

This is normally a **maintainer task**, not a report-user task. If you need to rebuild the billing meter uplift master data, follow [Creating billing meter uplift master data](MASTER-DATA.md).

That guide covers the four preparation steps:

1. Export the Retail Prices API catalogue to JSON.
2. Import JSON into Excel and map pricing changes to billing meter IDs.
3. Export the meter uplift tables to CSV.
4. Convert CSV to Parquet for the report.
