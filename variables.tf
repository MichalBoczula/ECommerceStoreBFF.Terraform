variable "subscription_id" {
  description = "Azure subscription UUID; the shared environment and Products app must be in this subscription."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "Use the subscription UUID, not its display name."
  }
}

variable "environment" {
  description = "Environment name used in BFF and default Products resource names."
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Choose dev, test, or prod."
  }
}

variable "shared_environment" {
  description = "Existing Products-owned ACA environment. Null selects cae-ecommercestore-products-<environment> in rg-ecommercestore-products-<environment>."
  type = object({
    name                = string
    resource_group_name = string
  })
  default = null

  validation {
    condition = var.shared_environment == null ? true : (
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$", var.shared_environment.name)) &&
      can(regex("^[a-zA-Z0-9_-]{1,90}$", var.shared_environment.resource_group_name))
    )
    error_message = "Supply the existing ACA environment name and resource group name, without URLs or resource IDs."
  }
}

variable "products_app" {
  description = "Existing Products app. Null selects ca-ecommercestore-products-<environment> in rg-ecommercestore-products-<environment>."
  type = object({
    name                = string
    resource_group_name = string
  })
  default = null

  validation {
    condition = var.products_app == null ? true : (
      can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", var.products_app.name)) &&
      !strcontains(var.products_app.name, "--") &&
      can(regex("^[a-zA-Z0-9_-]{1,90}$", var.products_app.resource_group_name))
    )
    error_message = "Supply the existing Products Container App name and resource group name."
  }
}

variable "bff_image" {
  description = "Published public BFF image pinned by SHA-256 digest. No floating tags or registry credentials."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^mb0101/ecommerce-store-bff-api@sha256:[0-9a-f]{64}$", var.bff_image))
    error_message = "Use mb0101/ecommerce-store-bff-api@sha256:<64 lowercase hex characters> from a successfully published build."
  }
}

variable "external_ingress_enabled" {
  description = "Enable only for the SWA linking step. The web stack owns the link and its Azure Static Web Apps (Linked) authentication provider."
  type        = bool
  default     = false
  nullable    = false
}

variable "min_replicas" {
  description = "0 permits scale to zero; temporarily use 1 for console access and portfolio verification, then restore 0. Maximum remains 1."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = contains([0, 1], var.min_replicas)
    error_message = "Choose 0 or 1; the portfolio app is capped at one replica."
  }
}
