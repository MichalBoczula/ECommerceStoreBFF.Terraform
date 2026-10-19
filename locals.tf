locals {
  names = {
    resource_group = "rg-ecommercestore-bff-${var.environment}"
    app            = "ca-ecommercestore-bff-${var.environment}"
  }

  shared_environment = var.shared_environment == null ? {
    name                = "cae-ecommercestore-products-${var.environment}"
    resource_group_name = "rg-ecommercestore-products-${var.environment}"
  } : var.shared_environment

  products_app = var.products_app == null ? {
    name                = "ca-ecommercestore-products-${var.environment}"
    resource_group_name = "rg-ecommercestore-products-${var.environment}"
  } : var.products_app

  products_base_url = try("https://${data.azurerm_container_app.products.ingress[0].fqdn}", "")

  container_environment = merge(
    jsondecode(file("${path.module}/config/bff-environment.json")),
    {
      ReverseProxy__Clusters__products-cluster__Destinations__destination1__Address = local.products_base_url
    }
  )

  tags = {
    application = "EcommerceStore"
    component   = "BFF"
    environment = var.environment
    managed_by  = "Terraform"
    purpose     = "portfolio"
  }
}
