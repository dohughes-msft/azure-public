#Requires -Version 7.0
<#
.SYNOPSIS
    Collects Azure retail prices for Compute Virtual Machines and all Storage services.
.DESCRIPTION
    Follows every API page across all regions, including global and non-primary
    meters. Writes only serviceFamily, serviceName, productName, skuName, Type,
    armRegionName, meterName, and meterId.
    Writes one JSON array per family without buffering the entire dataset.
.PARAMETER OutputDirectory
    Output directory. Defaults to the json subfolder beside this script.
.EXAMPLE
    .\Get-PricingData.ps1 -Verbose
.EXAMPLE
    .\Get-PricingData.ps1 -OutputDirectory .\baseline
.NOTES
    Public retail prices, not customer-negotiated prices or a forecast of 2027 prices.
    https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'json')
)

$ErrorActionPreference = 'Stop'
$baseUri = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview'

function Invoke-WithRetry {
    param([string] $Url)

    $maxRetries = 5
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 120 -ErrorAction Stop
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) {
                [int] $_.Exception.Response.StatusCode
            } elseif ($null -ne $_.Exception.StatusCode) {
                [int] $_.Exception.StatusCode
            } else {
                $null
            }

            if ($attempt -eq $maxRetries -or
                ($null -ne $statusCode -and $statusCode -notin @(408, 429, 500, 502, 503, 504))) {
                throw
            }

            $delay = [Math]::Min(5 * [Math]::Pow(2, $attempt), 60)
            Write-Warning "Pricing request failed: $($_.Exception.Message). Retrying in $delay seconds ($($attempt + 1)/$maxRetries)."
            Start-Sleep -Seconds $delay
        }
    }
}

$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null

foreach ($family in @('Compute', 'Storage')) {
    $filterExpression = "serviceFamily eq '$family'"
    if ($family -eq 'Compute') {
        $filterExpression += " and serviceName eq 'Virtual Machines'"
    }
    $filter = [Uri]::EscapeDataString($filterExpression)
    $url = "$baseUri&`$filter=$filter"
    $filePath = Join-Path $outputPath "pricing_$($family.ToLowerInvariant()).json"
    $temporaryPath = "$filePath.$([Guid]::NewGuid().ToString('N')).partial"
    $writer = $null
    $recordCount = 0L
    $pageCount = 0

    try {
        $writer = [System.IO.StreamWriter]::new($temporaryPath, $false, [System.Text.UTF8Encoding]::new($false))
        $writer.Write('[')

        do {
            Write-Progress -Activity 'Collecting Azure retail prices' -Status "$family : page $($pageCount + 1), $recordCount records"
            $response = Invoke-WithRetry -Url $url
            if ($null -eq $response -or
                $null -eq $response.PSObject.Properties['Items'] -or
                $null -eq $response.Items -or
                $null -eq $response.PSObject.Properties['NextPageLink']) {
                throw "Invalid pricing API response for $family at $url."
            }

            foreach ($item in $response.Items) {
                if ($null -eq $item -or $item.serviceFamily -cne $family) {
                    throw "The pricing API returned a record outside the requested $family scope."
                }
                if ($family -eq 'Compute' -and $item.serviceName -cne 'Virtual Machines') {
                    throw "The pricing API returned a Compute record outside the requested Virtual Machines service scope."
                }

                $outputItem = [pscustomobject][ordered]@{
                    serviceFamily = $item.serviceFamily
                    serviceName   = $item.serviceName
                    productName   = $item.productName
                    skuName       = $item.skuName
                    Type          = $item.type
                    armRegionName = $item.armRegionName
                    meterName     = $item.meterName
                    meterId       = $item.meterId
                }

                if ($recordCount -gt 0) {
                    $writer.Write(',')
                }
                $writer.WriteLine()
                $writer.Write((ConvertTo-Json -InputObject $outputItem -Depth 100 -Compress))
                $recordCount++
            }

            $pageCount++
            Write-Verbose "$family : page $pageCount fetched, $recordCount records collected."
            $url = $response.NextPageLink
        } while (-not [string]::IsNullOrWhiteSpace($url))

        if ($recordCount -eq 0) {
            throw "No $family prices returned for the requested scope."
        }

        $writer.WriteLine()
        $writer.WriteLine(']')
        $writer.Dispose()
        $writer = $null

        # Only replace a completed snapshot after every page for this family succeeds.
        Move-Item -LiteralPath $temporaryPath -Destination $filePath -Force
        Write-Host "$family : saved $recordCount records from $pageCount pages to $filePath"
        [pscustomobject]@{
            ServiceFamily = $family
            RecordCount   = $recordCount
            PageCount     = $pageCount
            FilePath      = $filePath
        }
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        Write-Progress -Activity 'Collecting Azure retail prices' -Completed
    }
}
