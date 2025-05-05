<#
.SYNOPSIS
    Deploy an Azure policy to restrict VM families and SKUs
.DESCRIPTION
    This script creates a policy definition in Azure that restricts the use of older VM families and SKUs.
    The policy is designed to prevent the deployment of Azure Virtual Machines and Virtual Machine Scale Sets with outdated SKUs.
.NOTES
.EXAMPLE
#>

$policyName = "VmModernisationPolicy"
$policyDisplayName = "Prevent use of older VM SKUs"
$policyDescription = "Deny Azure Virtual Machines and Virtual Machine Scaleset Deployments that use old VM families"
$policyDefinitionFile = "PolicyDefinitionVmModernisation.json"
$policyMetadata = '{"category":"Compute"}'
$subscriptionId = "69f95403-8f1d-40b6-8ff0-beba8f41adea"

New-AzPolicyDefinition `
    -Name $policyName `
    -DisplayName $policyDisplayName `
    -Description $policyDescription `
    -Policy $policyDefinitionFile `
    -Mode All `
    -Metadata $policyMetadata `
    -SubscriptionId $subscriptionId
