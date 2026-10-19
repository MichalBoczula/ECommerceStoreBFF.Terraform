# These objects are read from Azure, never imported into this root's state as
# managed resources. Products retains ownership of the environment and network.
data "azurerm_container_app_environment" "shared" {
  name                = local.shared_environment.name
  resource_group_name = local.shared_environment.resource_group_name
}

data "azurerm_container_app" "products" {
  name                = local.products_app.name
  resource_group_name = local.products_app.resource_group_name
  read_secrets        = false
}

resource "azurerm_resource_group" "bff" {
  name     = local.names.resource_group
  location = data.azurerm_container_app_environment.shared.location
  tags     = local.tags
}

resource "azurerm_container_app" "bff" {
  name                         = local.names.app
  resource_group_name          = azurerm_resource_group.bff.name
  container_app_environment_id = data.azurerm_container_app_environment.shared.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"
  tags                         = local.tags

  ingress {
    external_enabled           = var.external_ingress_enabled
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    http_scale_rule {
      name                = "http"
      concurrent_requests = "10"
    }

    container {
      name   = "bff"
      image  = var.bff_image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = local.container_environment
        content {
          name  = env.key
          value = env.value
        }
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 5
        timeout                 = 3
        failure_count_threshold = 60
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 3
        success_count_threshold = 1
        failure_count_threshold = 3
      }
    }
  }

  lifecycle {
    precondition {
      condition     = lower(data.azurerm_container_app.products.container_app_environment_id) == lower(data.azurerm_container_app_environment.shared.id)
      error_message = "Products and BFF must be in the same ACA environment to use Products internal ingress."
    }

    precondition {
      condition     = try(data.azurerm_container_app.products.ingress[0].fqdn != "", false)
      error_message = "The existing Products app must have HTTP ingress and an assigned FQDN. Deploy Products before planning BFF."
    }

    precondition {
      condition = !var.external_ingress_enabled || (
        !data.azurerm_container_app_environment.shared.internal_load_balancer_enabled &&
        data.azurerm_container_app_environment.shared.public_network_access == "Enabled"
      )
      error_message = "SWA linking needs an externally reachable ACA environment. Keep ingress internal when the shared environment is network isolated."
    }
  }
}
