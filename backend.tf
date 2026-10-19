terraform {
  backend "azurerm" {
    use_cli          = true
    use_azuread_auth = true
  }
}
