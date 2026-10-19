provider "azurerm" {
  subscription_id = var.subscription_id
  use_cli         = true

  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.App"]

  features {}
}
