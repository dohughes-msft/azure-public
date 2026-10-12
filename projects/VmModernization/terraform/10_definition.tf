resource "azurerm_policy_definition" "vm_modernisation_policy" {
  name         = "VmModernisationPolicy"
  display_name = "Prevent use of older VM SKUs"
  description  = "Deny Azure Virtual Machines and Virtual Machine scale set deployments that use old VM families"
  policy_type  = "Custom"
  mode         = "All"
  policy_rule  = <<POLICY_RULE
{
  "if": {
    "AllOf": [
      {
        "AnyOf": [
          {
            "field": "type",
            "in": [
              "Microsoft.Compute/virtualMachines"
            ]
          },
          {
            "field": "type",
            "in": [
              "Microsoft.Compute/virtualMachineScaleSets"
            ]
          }
        ]
      },
      {
        "anyOf": [
          {
            "AllOf": [
              {
                "field": "Microsoft.Compute/virtualMachines/sku.name",
                "in": "[parameters('BlockedSKUs')]"
              },
              {
                "field": "Microsoft.Compute/virtualMachines/priority",
                "notEquals": "Spot"
              }
            ]
          },
          {
            "AllOf": [
              {
                "field": "Microsoft.Compute/virtualMachineScaleSets/sku.name",
                "in": "[parameters('BlockedSKUs')]"
              },
              {
                "field": "Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.priority",
                "notEquals": "Spot"
              }
            ]
          }
        ]
      }
    ]
  },
  "then": {
    "effect": "[parameters('Effect')]"
  }
}
POLICY_RULE

  parameters = <<PARAMETERS
{
  "BlockedSKUs": {
    "type": "Array",
    "metadata": {
      "displayName": "Blocked SKUs",
      "description": "The list of VM SKUs to block"
    }
  },
  "Effect": {
    "type": "String",
    "allowedValues": [
      "Audit",
      "Deny"
    ],
    "metadata": {
      "displayName": "Policy effect"
    }
  }
}
PARAMETERS

  metadata = <<METADATA
{
    "category": "Compute"
}
METADATA
}
