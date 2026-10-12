<#
.SYNOPSIS
    Create an Excel file containing VM families and SKUs
.DESCRIPTION
    This script retrieves the list of VM families and SKUs from Azure and exports them to an Excel file with two tabs:
    1. A list of unique VM families
    2. A list of VM families and their corresponding SKUs
.NOTES
    This script requires the Az PowerShell module and the ImportExcel module to be installed.
    The output file will be created in the current directory unless a different path is specified.
.EXAMPLE
    Get-VMFamilies.ps1 -outputFile "CustomVMFamilies.xlsx"
#>

$skuData = Get-AzComputeResourceSku | Where-Object ResourceType -eq "virtualMachines" | Select-Object Family, Name -Unique

# File 1 - the list of families
$fileName = "VMFamily.csv"
$tab1Data = $skuData | Select-Object Family -Unique | Sort-Object Family
$tab1Data | Export-Csv -Path $fileName -NoTypeInformation
Write-Output "$($tab1Data.Count) results written to $fileName"

# File 2 - families and SKUs
$fileName = "VMFamilyAndSKU.csv"
$tab2Data = $skuData | Sort-Object Family, Name
$tab2Data | Export-Csv -Path $fileName -NoTypeInformation
Write-Output "$($tab2Data.Count) results written to $fileName"
