# Creating billing meter uplift master data (optional)

This guide is for maintainers who create or update the billing meter uplift master data. Report end-users normally use the supplied Parquet files and do not need to perform these steps.

For placing customer amortized usage files and starting Power BI, see the [report user guide](README.md).

The master-data preparation workflow is:

1. Export the Azure Retail Prices API data to JSON (PowerShell).
2. Import the JSON into Excel and map pricing-change rules to billing meter IDs. This step requires the most manual work.
3. Export the completed Compute and Storage meter tables from Excel to CSV.
4. Convert the CSV files to Parquet (Python).

```text
Azure Retail Prices API
        |
        |  JSON files
        v
Excel to map price change to billing meter ID
        |
        |  CSV files
        v
Parquet files ready for consumption in Power BI
```

## Project layout

```text
BillingMeterPreparation/
|-- 01-Get-PricingData.ps1                 Retail Prices API export
|-- 02-ConstructBillingMeters.xlsm         Pricing-rule and meter mapping workbook
|-- 03-ConvertToParquet.py                 CSV-to-Parquet conversion
|-- csv/
|   |-- ComputeMeters.csv                  Excel export for Compute meters
|   `-- StorageMeters.csv                  Excel export for Storage meters
`-- json/
    |-- pricing_compute.json               Generated Compute pricing data
    `-- pricing_storage.json               Generated Storage pricing data

..\MasterData/                             Parquet output location
|-- ComputeMeters.parquet
`-- StorageMeters.parquet
```

Customer usage exports, generated meter data, and Power BI report files can contain sensitive or large data. They are excluded by the project `.gitignore`; do not commit them.

## Prerequisites

- PowerShell 7 or later.
- Internet access to `https://prices.azure.com`.
- Microsoft Excel with Power Query, `XLOOKUP`, and `XMATCH`.
- Python 3 with `pandas` and `pyarrow`.

Install the Python dependencies if they are not already available:

```powershell
python -m pip install pandas pyarrow
```

No Azure sign-in, Azure subscription, or Az PowerShell module is required to export public retail prices.

## 1. Export retail pricing to JSON

From the project directory, run:

```powershell
Set-Location .\BillingMeterPreparation
.\01-Get-PricingData.ps1 -Verbose
```

The script always exports only the eight fields required by the Excel mapping workbook:

- `serviceFamily`
- `serviceName`
- `productName`
- `skuName`
- `Type`
- `armRegionName`
- `meterName`
- `meterId`

The reduced schema does not reduce the number of API records or pages collected.

Each run writes to the `json` subfolder beside the script:

```text
BillingMeterPreparation/json/
|-- pricing_compute.json
`-- pricing_storage.json
```

Successful runs replace the existing JSON files in this folder. Copy them elsewhere before running if you need to retain an earlier snapshot.

The Compute export is limited to the `Compute` service family and `Virtual Machines` service. The Storage export includes the complete `Storage` service family. All regions and all pages returned by the API are collected.

An explicit output folder can be supplied when required:

```powershell
.\01-Get-PricingData.ps1 `
    -OutputDirectory .\baseline `
    -Verbose
```

These files contain public retail pricing catalogue data available at collection time.

## 2. Import JSON into Excel and map pricing changes

Open `BillingMeterPreparation\02-ConstructBillingMeters.xlsm`.

The workbook uses these Power Query queries:

| Query | Purpose |
|---|---|
| `RootDirectory` | Required text parameter containing the folder with the selected JSON snapshot. |
| `ComputeFull` | Reads `pricing_compute.json`, keeps `Type = "Consumption"`, and outputs distinct service, product, region, and meter ID rows. |
| `StorageFull` | Reads `pricing_storage.json`, keeps `Type = "Consumption"`, and outputs distinct service, product, region, and meter ID rows. |
| `ComputeHierarchyTemplate` | Selects and sorts distinct Compute service-family, service-name, and product-name combinations from `ComputeFull`. |
| `StorageHierarchyTemplate` | Selects and sorts distinct Storage service-family, service-name, and product-name combinations from `StorageFull`. |

### Point the queries at the latest snapshot

The queries use the shared `RootDirectory` parameter and append the JSON filenames themselves. In Excel:

1. Select **Data > Queries & Connections**.
2. Open the Power Query Editor and select **Home > Manage Parameters**.
3. Set `RootDirectory` to the full path of `BillingMeterPreparation\json`, for example `C:\...\BillingMeterPreparation\json`. Do not include a JSON filename or a trailing slash. If you supplied `-OutputDirectory`, use that folder instead.
4. Refresh the queries and confirm that `ComputeFull` and `StorageFull` return rows. The queries retain only `Type = "Consumption"` and remove duplicates across service family, service name, product name, ARM region, and meter ID.

If rebuilding the queries, load the appropriate JSON file, convert its top-level list to a table, expand `serviceFamily`, `serviceName`, `productName`, `skuName`, `Type`, `armRegionName`, `meterName`, and `meterId`, then apply the same Consumption filter, selected columns, distinct operation, and text types used by the existing queries.

### Build the static hierarchy tables

For both `ComputeHierarchyTemplate` and `StorageHierarchyTemplate` (which should remain as connection-only template queries):

1. Duplicate the template query.
2. Load the duplicate to an Excel table.
3. Delete only the duplicated query after its data has loaded. This leaves the table as a static mapping that will not be overwritten by a later refresh.
4. Manually classify the products affected by each pricing change.

The resulting tables are:

#### `ComputeHierarchy`

| Column | Description |
|---|---|
| `Service Family` | Azure service family. |
| `Service Name` | Azure service name. |
| `Product Name` | Retail catalogue product name. |
| `InRetirementScope` | `TRUE` when the product is in scope for the retirement uplift. |
| `RetirementUplift%` | Uplift percentage for retirement-scope products. |
| `InConstrainedScope` | `TRUE` when the product is in scope for constrained-region pricing. |
| `Key` | Concatenation of service family, service name, and product name. |

The `Key` formula is:

```excel
=[@[Service Family]]&"|"&[@[Service Name]]&"|"&[@[Product Name]]
```

#### `StorageHierarchy`

| Column | Description |
|---|---|
| `Service Family` | Azure service family. |
| `Service Name` | Azure service name. |
| `Product Name` | Retail catalogue product name. |
| `InConstrainedScope` | `TRUE` when the product is in scope for constrained-region pricing. |
| `Key` | Concatenation of service family, service name, and product name. |

### Maintain constrained-region uplifts

The `Constrained` sheet contains the `ConstrainedRegions` table:

| Column | Description |
|---|---|
| `Region` | Friendly region name. |
| `Technical Name` | ARM region name used by the pricing and usage data. |
| `Uplift%` | Uplift percentage for the region. |

Use the technical ARM name, such as `westeurope`, for matching. Region matching must not rely on the friendly display name.

### Build meter-level tables

Duplicate `ComputeFull` and `StorageFull`, load each duplicate to a table, and then delete the duplicated queries (not the original queries) so the loaded meter lists become static. The duplicates should load the `ComputeMeters` and `StorageMeters` tables. The source queries themselves filter to Consumption meters and retain distinct service, product, region, and meter ID combinations.

The workbook maps each meter to its hierarchy and region rules.

For Compute:

- `RetirementUpliftApplies` looks up `InRetirementScope` in `ComputeHierarchy`.
- `RetirementUplift%` looks up the hierarchy uplift when retirement uplift applies.
- `ConstrainedSKU` looks up `InConstrainedScope`.
- `ConstrainedRegion` checks the ARM region against `ConstrainedRegions`.
- `ConstrainedUpliftApplies` is true only when retirement uplift does not apply and both the SKU and region are constrained.
- `ConstrainedUplift%` looks up the matching constrained-region uplift.

For Storage:

- `ConstrainedSKU` looks up `InConstrainedScope` in `StorageHierarchy`.
- `ConstrainedRegion` checks the ARM region against `ConstrainedRegions`.
- `ConstrainedUpliftApplies` is true when both the SKU and region are constrained.
- `ConstrainedUplift%` looks up the matching constrained-region uplift.

Before exporting, verify:

- There are no `NOT FOUND` results in the lookup columns.
- All expected uplift percentages are populated.
- `Meter ID` values are stored as text and are not blank.
- ARM region names match the technical names in `ConstrainedRegions`.
- Retirement and constrained uplift rules are mutually exclusive where intended.

## 3. Export meter tables from Excel to CSV

Export the completed `ComputeMeters` and `StorageMeters` tables as UTF-8 CSV files in `BillingMeterPreparation\csv`:

```text
BillingMeterPreparation/csv/ComputeMeters.csv
BillingMeterPreparation/csv/StorageMeters.csv
```

One safe method is to copy each completed table to a separate temporary workbook and use **File > Save As > CSV UTF-8 (Comma delimited)**. This avoids converting or overwriting the mapping workbook itself.

The expected Compute CSV header is:

```text
Service Family,Service Name,Product Name,ARM Region Name,Meter ID,RetirementUpliftApplies,RetirementUplift%,ConstrainedSKU,ConstrainedRegion,ConstrainedUpliftApplies,ConstrainedUplift%
```

The expected Storage CSV header is:

```text
Service Family,Service Name,Product Name,ARM Region Name,Meter ID,ConstrainedSKU,ConstrainedRegion,ConstrainedUpliftApplies,ConstrainedUplift%
```

Do not rename these files or columns unless `03-ConvertToParquet.py` and the Power BI queries are updated at the same time.

## 4. Convert CSV to Parquet

Run the conversion from `BillingMeterPreparation`, because the script uses paths relative to that directory. If you are still there after step 1, skip `Set-Location`; otherwise run the following from the project directory:

```powershell
Set-Location .\BillingMeterPreparation
python .\03-ConvertToParquet.py
```

The script reads:

```text
csv\ComputeMeters.csv
csv\StorageMeters.csv
```

and writes Snappy-compressed Parquet files to:

```text
..\MasterData\ComputeMeters.parquet
..\MasterData\StorageMeters.parquet
```

Existing files with those names are replaced.

Optionally validate the generated files:

```powershell
python -c "import pandas as pd; from pathlib import Path; [print(p.name, len(pd.read_parquet(p)), list(pd.read_parquet(p).columns)) for p in Path(r'..\MasterData').glob('*.parquet')]"
```

Confirm that both files contain rows and that their columns match the corresponding CSV schemas.

The master data is now ready for the report. Continue with the [report user guide](README.md).

## Refresh checklist

For each new pricing snapshot or rule revision:

1. Run `01-Get-PricingData.ps1`.
2. Refresh the Excel source queries against the updated JSON files in `BillingMeterPreparation\json` (or your explicit output directory).
3. Rebuild and review the static hierarchy tables.
4. Apply or update pricing-change classifications and constrained-region percentages.
5. Rebuild the meter tables and check for missing lookups.
6. Export `ComputeMeters.csv` and `StorageMeters.csv`.
7. Run `03-ConvertToParquet.py`.
8. Refresh Power BI against the updated master data and review unmatched meters and reconciliation totals before distributing the report.

## Troubleshooting

### The pricing export takes a long time

The script follows every API page for all applicable regions. The eight-field output reduces record width but does not reduce page count.

### Excel reports `NOT FOUND`

The product hierarchy may have changed since the previous snapshot. Refresh the hierarchy templates, classify the new products, and confirm that the key uses the exact service family, service name, and product name from the current JSON.

### Python cannot write Parquet

Install the required engine:

```powershell
python -m pip install pyarrow
```

Also confirm the command is being run from `BillingMeterPreparation`.

## References

- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Power BI Parquet connector](https://learn.microsoft.com/power-query/connectors/parquet)
