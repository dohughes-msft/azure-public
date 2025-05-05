# Terraform has different providers for different scopes: subscription, management group, and resource group.
# Check and use the correct provider for your scope.

# Read the disallowed SKUs from the JSON file
locals {
  effect = "Audit"
  disallowed_skus = jsondecode(file("${path.module}/DisallowedSkus.json"))
  scope_type = "sub"   # Change to "mg" for management group or "rg" for resource group
  scope = "/subscriptions/69f95403-8f1d-40b6-8ff0-beba8f41adea"
}

# Policy assignment(s)

# Subscription scope
resource "azurerm_subscription_policy_assignment" "restrict_older_vms" {
  count                = local.scope_type == "sub" ? 1 : 0
  name                 = "RestrictOlderVMs"
  display_name         = "Restrict Older VM SKUs"
  description          = "Restrict the use of older VM SKUs in the scope"
  policy_definition_id = azurerm_policy_definition.vm_modernisation_policy.id
  subscription_id      = local.scope

  # Policy parameters
  parameters = jsonencode({
    Effect      = { value = local.effect }
    BlockedSKUs = { value = local.disallowed_skus }
  })

  non_compliance_message {
    content = "Older VM SKUs are not allowed. Please use a newer SKU."
  }
}

/*

# Management group scope
resource "azurerm_management_group_policy_assignment" "restrict_older_vms" {
  count                = local.scope_type == "mg" ? 1 : 0
  name                 = "RestrictOlderVMs"
  display_name         = "Restrict Older VM SKUs"
  description          = "Restrict the use of older VM SKUs in the scope"
  policy_definition_id = azurerm_policy_definition.vm_modernisation_policy.id
  management_group_id  = local.scope

  # Policy parameters
  parameters = jsonencode({
    Effect      = { value = local.effect }
    BlockedSKUs = { value = local.disallowed_skus }
  })

  non_compliance_message {
    content = "Older VM SKUs are not allowed. Please use a newer SKU."
  }
}

# Resource group scope
resource "azurerm_resource_group_policy_assignment" "restrict_older_vms" {
  count                = local.scope_type == "rg" ? 1 : 0
  name                 = "RestrictOlderVMs"
  display_name         = "Restrict Older VM SKUs"
  description          = "Restrict the use of older VM SKUs in the scope"
  policy_definition_id = azurerm_policy_definition.vm_modernisation_policy.id
  resource_group_id    = local.scope

  # Policy parameters
  parameters = jsonencode({
    Effect      = { value = local.effect }
    BlockedSKUs = { value = local.disallowed_skus }
  })

  non_compliance_message {
    content = "Older VM SKUs are not allowed. Please use a newer SKU."
  }
}

*/