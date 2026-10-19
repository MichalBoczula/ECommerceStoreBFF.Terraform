mock_provider "azurerm" {
  override_during = plan
}

override_data {
  target          = data.azurerm_container_app_environment.shared
  override_during = plan
  values = {
    id                             = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.App/managedEnvironments/cae-ecommercestore-products-dev"
    location                       = "northeurope"
    internal_load_balancer_enabled = false
    public_network_access          = "Enabled"
  }
}

override_data {
  target          = data.azurerm_container_app.products
  override_during = plan
  values = {
    container_app_environment_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.App/managedEnvironments/cae-ecommercestore-products-dev"
    ingress = [{
      fqdn             = "ca-ecommercestore-products-dev.internal.example.northeurope.azurecontainerapps.io"
      external_enabled = false
      target_port      = 8080
    }]
  }
}

override_resource {
  target          = azurerm_container_app.bff
  override_during = plan
  values = {
    id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-bff-dev/providers/Microsoft.App/containerApps/ca-ecommercestore-bff-dev"
    location = "northeurope"
  }
}

variables {
  subscription_id = "11111111-1111-1111-1111-111111111111"
  bff_image       = "mb0101/ecommerce-store-bff-api@sha256:ccf624855827c6ca0d59ffbf4b19459ad0d5899bbe997ba90ecabfd5e528873a"
}

run "internal_catalogue_bff" {
  command = plan

  assert {
    condition = (
      azurerm_resource_group.bff.name == "rg-ecommercestore-bff-dev" &&
      azurerm_resource_group.bff.location == "northeurope" &&
      azurerm_container_app.bff.name == "ca-ecommercestore-bff-dev" &&
      azurerm_container_app.bff.container_app_environment_id == data.azurerm_container_app_environment.shared.id &&
      !data.azurerm_container_app.products.read_secrets &&
      data.azurerm_container_app.products.name == "ca-ecommercestore-products-dev"
    )
    error_message = "BFF must reuse the Products environment without reading Products secret values."
  }

  assert {
    condition = (
      !azurerm_container_app.bff.ingress[0].external_enabled &&
      !azurerm_container_app.bff.ingress[0].allow_insecure_connections &&
      azurerm_container_app.bff.ingress[0].target_port == 8080 &&
      azurerm_container_app.bff.revision_mode == "Single" &&
      azurerm_container_app.bff.workload_profile_name == "Consumption" &&
      azurerm_container_app.bff.template[0].container[0].cpu == 0.25 &&
      azurerm_container_app.bff.template[0].container[0].memory == "0.5Gi" &&
      azurerm_container_app.bff.template[0].min_replicas == 0 &&
      azurerm_container_app.bff.template[0].max_replicas == 1
    )
    error_message = "Use HTTPS internal ingress, Consumption, and zero to one small replicas by default."
  }

  assert {
    condition = (
      azurerm_container_app.bff.template[0].container[0].startup_probe[0].path == "/health" &&
      azurerm_container_app.bff.template[0].container[0].liveness_probe[0].path == "/health" &&
      azurerm_container_app.bff.template[0].container[0].readiness_probe[0].path == "/health" &&
      output.bff_deployment.products_base_url == "https://ca-ecommercestore-products-dev.internal.example.northeurope.azurecontainerapps.io" &&
      output.bff_deployment.health_path == "/health" &&
      output.bff_deployment.id == azurerm_container_app.bff.id
    )
    error_message = "Use the BFF's actual /health endpoint and the existing Products HTTPS FQDN."
  }

  assert {
    condition = alltrue([
      for key, value in {
        GatewaySettings__BaseUrl                                                      = "http://localhost:8080"
        ReverseProxy__Clusters__products-cluster__Destinations__destination1__Address = "https://ca-ecommercestore-products-dev.internal.example.northeurope.azurecontainerapps.io"
        ReverseProxy__Routes__swa-mobile-phones__Match__Path                          = "/api/mobile-phones/{**remainder}"
        ReverseProxy__Routes__swa-mobile-phones__Transforms__0__PathRemovePrefix      = "/api"
        ReverseProxy__Routes__swa-categories__Match__Path                             = "/api/categories/{**remainder}"
        ReverseProxy__Routes__swa-currencies__Match__Path                             = "/api/currencies/{**remainder}"
      } : one([for item in azurerm_container_app.bff.template[0].container[0].env : item.value if item.name == key]) == value
    ])
    error_message = "Pass the deployed Products URL and /api prefix removal into the actual container environment."
  }
}

run "temporary_console_replica" {
  command = plan
  variables {
    min_replicas = 1
  }
  assert {
    condition = (
      azurerm_container_app.bff.template[0].min_replicas == 1 &&
      azurerm_container_app.bff.template[0].max_replicas == 1 &&
      !azurerm_container_app.bff.ingress[0].external_enabled
    )
    error_message = "Console diagnostics must be possible without opening public ingress or removing the replica cap."
  }
}

run "external_ingress_for_swa" {
  command = plan
  variables {
    external_ingress_enabled = true
  }
  assert {
    condition     = azurerm_container_app.bff.ingress[0].external_enabled && output.bff_deployment.external_ingress
    error_message = "SWA linking requires explicit external ingress. The web stack owns linked authentication."
  }
}

run "custom_existing_targets" {
  command = plan
  variables {
    environment = "test"
    shared_environment = {
      name                = "cae-shared-test"
      resource_group_name = "rg-shared-test"
    }
    products_app = {
      name                = "ca-products-test"
      resource_group_name = "rg-products-test"
    }
  }
  assert {
    condition = (
      azurerm_container_app.bff.name == "ca-ecommercestore-bff-test" &&
      data.azurerm_container_app_environment.shared.name == "cae-shared-test" &&
      data.azurerm_container_app.products.name == "ca-products-test"
    )
    error_message = "Alternate existing targets must be read explicitly, with BFF names derived from its environment."
  }
}

run "reject_different_products_environment" {
  command = plan
  override_data {
    target = data.azurerm_container_app.products
    values = {
      container_app_environment_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-other/providers/Microsoft.App/managedEnvironments/cae-other"
      ingress                      = [{ fqdn = "products.internal.other.azurecontainerapps.io" }]
    }
  }
  expect_failures = [azurerm_container_app.bff]
}

run "reject_products_without_ingress" {
  command = plan
  override_data {
    target = data.azurerm_container_app.products
    values = {
      container_app_environment_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.App/managedEnvironments/cae-ecommercestore-products-dev"
      ingress                      = []
    }
  }
  expect_failures = [azurerm_container_app.bff]
}

run "reject_external_in_isolated_environment" {
  command = plan
  variables {
    external_ingress_enabled = true
  }
  override_data {
    target = data.azurerm_container_app_environment.shared
    values = {
      id                             = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.App/managedEnvironments/cae-ecommercestore-products-dev"
      location                       = "northeurope"
      internal_load_balancer_enabled = true
      public_network_access          = "Disabled"
    }
  }
  expect_failures = [azurerm_container_app.bff]
}

run "reject_subscription_name" {
  command = plan
  variables {
    subscription_id = "Portfolio"
  }
  expect_failures = [var.subscription_id]
}

run "reject_floating_image" {
  command = plan
  variables {
    bff_image = "mb0101/ecommerce-store-bff-api:latest"
  }
  expect_failures = [var.bff_image]
}

run "reject_non_bff_image" {
  command = plan
  variables {
    bff_image = "mb0101/product-catalog-api@sha256:ccf624855827c6ca0d59ffbf4b19459ad0d5899bbe997ba90ecabfd5e528873a"
  }
  expect_failures = [var.bff_image]
}

run "reject_unknown_environment" {
  command = plan
  variables {
    environment = "development"
  }
  expect_failures = [var.environment]
}

run "reject_replica_cost_increase" {
  command = plan
  variables {
    min_replicas = 2
  }
  expect_failures = [var.min_replicas]
}

run "reject_environment_url" {
  command = plan
  variables {
    shared_environment = {
      name                = "https://environment.example.com"
      resource_group_name = "rg-example"
    }
  }
  expect_failures = [var.shared_environment]
}

run "reject_products_resource_id_as_name" {
  command = plan
  variables {
    products_app = {
      name                = "/subscriptions/example/providers/Microsoft.App/containerApps/app"
      resource_group_name = "rg-example"
    }
  }
  expect_failures = [var.products_app]
}
