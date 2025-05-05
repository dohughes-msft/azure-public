<#
.SYNOPSIS
    Assign an Azure policy to restrict VM families and SKUs
.DESCRIPTION
    This script assigns a policy to a scope in Azure that restricts the use of older VM families and SKUs.
    The policy is designed to prevent the deployment of Azure Virtual Machines and Virtual Machine Scale Sets with outdated SKUs.
.NOTES
.EXAMPLE
#>

$assignmentName = "RestrictOlderVMs"
$assignmentDisplayName = "Prevent use of older VM SKUs"
$policyName = "VmModernisationPolicy"
$nonComplianceMessage = @(
    @{
        Message = "Older VM SKUs are not allowed. Please use a newer SKU."
    }
)

# Scope may be a subscription, resource group, or management group
$scope = "/subscriptions/69f95403-8f1d-40b6-8ff0-beba8f41adea"

$skuListFile = "DisallowedSkus.json"
$parameterEffect = "Audit"
$parameterSkuList = Get-Content -Path $skuListFile | ConvertFrom-Json

$policyParameters = @{
    "Effect" = @{
        "value" = $parameterEffect
    }
    "BlockedSKUs" = @{
        "value" = $parameterSkuList
    }
} | ConvertTo-Json

# Useful for testing
<# 
$policyParameterObject = @{
    "Effect" = $parameterEffect
    "BlockedSKUs" = $parameterSkuList
} #>

<# 
$policyParameters = @{
    "Effect" = @{
        "value" = "Audit"
    }
    "BlockedSKUs" = @{
        "value" = @("Basic_A0","Basic_A1")
    }
} | ConvertTo-Json #>

$policyObject = Get-AzPolicyDefinition -Name $policyName

New-AzPolicyAssignment `
    -Name $assignmentName `
    -DisplayName $assignmentDisplayName `
    -PolicyDefinition $policyObject `
    -Scope "$scope" `
    -PolicyParameter $policyParameters `
    -NonComplianceMessage $nonComplianceMessage
