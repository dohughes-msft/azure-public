# Azure Advisor API call for emission reductions
# Requires Azure PowerShell module and authenticated session

# Parameters
# If restricting to specific subscriptions, define them here and adjust the query below. Otherwise use -UseTenantScope in Search-AzGraph.
$subscriptionList = @(
    "69f95403-8f1d-40b6-8ff0-beba8f41adea",
    "b42a8bcf-60dd-4f42-9172-abc08ad2f282"
)

$query = @'
advisorresources
  | where tolower(type) == "microsoft.advisor/recommendations"
  | extend RecommendationTypeId = tostring(properties.recommendationTypeId)
  | where RecommendationTypeId in ("94aea435-ef39-493f-a547-8408092c22a7", "e10b1381-5f0a-47ff-8c7b-37bd13d7c974")
  | where properties.lastUpdated >= ago(1d)
  | project stableId=name, subscriptionId, resourceGroup, properties, recommendationId=id
  | join kind=leftouter(
      advisorresources
      | where tolower(type) == 'microsoft.advisor/suppressions'
      | extend tokens = split(id, '/')
      | extend stableId = iff(array_length(tokens) > 3, tokens[(array_length(tokens)-3)], '')
      | extend expirationTimeStamp = todatetime(iff(strcmp(tostring(properties.ttl), '-1') == 0, '9999-12-31', properties.expirationTimeStamp))
      | where expirationTimeStamp > now()
      | project suppressionId = tostring(properties.suppressionId), stableId, expirationTimeStamp
  ) on stableId
  | join kind = leftouter (
      advisorresources
      | where tolower(type) == 'microsoft.advisor/configurations'
      | where isempty(resourceGroup) == true
      | project subscriptionId, excludeRecomm = properties.exclude, lowCpuThreshold = properties.lowCpuThreshold
  ) on subscriptionId
  | extend isActive = iff(isempty(excludeRecomm), true, tobool(excludeRecomm) == false)
  | extend isNotExcludedViaCpuThreshold = iff((isnotempty(lowCpuThreshold) and isnotnull(properties.extendedProperties) and isnotempty(properties.extendedProperties.MaxCpuP95)),
      todouble(properties.extendedProperties.MaxCpuP95) < todouble(lowCpuThreshold),
      iff((isnull(properties.extendedProperties) or isempty(properties.extendedProperties.MaxCpuP95) or todouble(properties.extendedProperties.MaxCpuP95) < 100),
          true,
          false))
  | where isActive == true and isNotExcludedViaCpuThreshold == true
  | join kind = leftouter (
      advisorresources
      | where type =~ 'microsoft.advisor/configurations'
      | where isnotempty(resourceGroup) == true
      | project subscriptionId, resourceGroup, excludeProperty = properties.exclude
  ) on subscriptionId, resourceGroup
  | extend shouldBeIncluded = iff(isempty(excludeProperty), true, tobool(excludeProperty) == false)
  | where shouldBeIncluded == true
  | summarize expirationTimeStamp = max(expirationTimeStamp), suppressionIds = make_list(suppressionId) by recommendationId, stableId, subscriptionId, resourceGroup, tostring(properties)
  | extend isRecommendationActive = (isnull(expirationTimeStamp) or isempty(expirationTimeStamp))
  | extend properties = parse_json(properties)
  | extend monthlyCostSavings = toreal(properties.extendedProperties.savingsAmount)
  | extend monthlyCarbonSavingsKg = toreal(properties.extendedProperties.PotentialMonthlyCarbonSavings)
  | where monthlyCarbonSavingsKg > 0
  | extend resourceId = properties.resourceMetadata.resourceId, resourceName = tostring(properties.extendedProperties.roleName), recommendationMessage = properties.extendedProperties.recommendationMessage, recommendationType=tostring(properties.extendedProperties.recommendationType)
  | project recommendationId, subscriptionId, resourceGroup, suppressionIds, isRecommendationActive, monthlyCostSavings, monthlyCarbonSavingsKg, resourceId, resourceName, recommendationMessage, recommendationType
  | where isRecommendationActive == true
  | order by monthlyCarbonSavingsKg desc
'@

# Execute the Resource Graph query
Write-Output "Executing Azure Resource Graph query for carbon emission reduction recommendations..."
#$results = Search-AzGraph -Query $query -Subscription $subscriptionList -First 1000
$results = Search-AzGraph -Query $query -UseTenantScope -First 1000

# Display results
$results | Format-Table -AutoSize

# Display summary
#Write-Output "`nTotal recommendations found: $($results.Count)"
#Write-Output "Total monthly carbon savings potential: $(($results | Measure-Object -Property monthlyCarbonSavingsKg -Sum).Sum) kg CO2"
#Write-Output "Total monthly cost savings potential: `$$(($results | Measure-Object -Property monthlyCostSavings -Sum).Sum)"
