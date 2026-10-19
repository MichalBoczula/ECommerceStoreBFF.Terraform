output "bff_deployment" {
  description = "Non-secret deployment, diagnostics, and SWA linking targets. Internal URLs are callable only inside the shared ACA environment."
  value = {
    subscription_id      = var.subscription_id
    resource_group_name  = azurerm_resource_group.bff.name
    name                 = azurerm_container_app.bff.name
    id                   = azurerm_container_app.bff.id
    location             = azurerm_container_app.bff.location
    aca_environment_id   = data.azurerm_container_app_environment.shared.id
    base_url             = "https://${azurerm_container_app.bff.ingress[0].fqdn}"
    external_ingress     = var.external_ingress_enabled
    image                = var.bff_image
    latest_revision_name = azurerm_container_app.bff.latest_revision_name
    min_replicas         = var.min_replicas
    products_base_url    = local.products_base_url
    products_api_path    = "/api/mobile-phones"
    health_path          = "/health"
    upstreams_deployed   = ["products"]
  }
}
