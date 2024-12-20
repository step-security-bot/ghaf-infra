# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "dns_suffix" {
  type = string
}

# Azure requires the entire Load Balancer config to be defined in a giant
# azurerm_application_gateway resource.
# This means we cannot create listeners and backend pools from other states,
# passing the name of the Application Gateway as an output, but instead need to
# accept the entire backend config as a variable and apply here.
# This is a map from the name before dns_suffix to the backend_fqdn.
variable "ingresses" {
  type = map  
}
# TODO: move vnet to other unit
resource "azurerm_virtual_network" "vnet" {
  name                = "default"
  address_space       = ["10.0.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group_name
}

# Slice out a subnet for the lb
resource "azurerm_subnet" "lb" {
  name                = "lb"
  resource_group_name = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/24"]
}

# Allocate a public IPv4 for the load balancer
# While we can allocate a static IPv6 address too,
# it'll fail due to the loadbalancer not being assigned to a IPv6 subnet, which
# doesn't seem to be possible to create.
resource "azurerm_public_ip" "lb_v4" {
  name                = "app-lb-v4"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_version = "IPv4"
  sku = "Standard"
  allocation_method   = "Static"
}

# # Key Vault for Certificate Storage
# resource "azurerm_key_vault" "cert_storage" {
#   name                = "lb-cert-storage"
#   location            = var.location
#   resource_group_name = var.resource_group_name
#   tenant_id           = data.azurerm_client_config.current.tenant_id
#   sku_name            = "standard"
# }

# # Allow access to the key vault
# # TODO: shouldn't this be granting to the App Gateway instead?
# resource "azurerm_key_vault_access_policy" "key_vault_access_policy" {
#   key_vault_id = azurerm_key_vault.cert_storage.id
#   tenant_id    = data.azurerm_client_config.current.tenant_id
#   object_id    = data.azurerm_client_config.current.object_id

#   certificate_permissions = ["Get", "List"]
#   secret_permissions      = ["Get", "List"]
# }

# Request a certificate
resource "azurerm_app_service_certificate_order" "cert_order" {
  name                = "cert-order-${each.key}"
  resource_group_name = var.resource_group_name
  location            = "global"
  distinguished_name  = "CN=${each.key}.${var.dns_suffix}"
  product_type        = "Standard"
  validity_in_years   = 1

  auto_renew = true

  for_each = var.ingresses
}

resource "azurerm_dns_txt_record" "validation_record" {
  name                = "_dnsauth.${each.key}"
  zone_name           = var.dns_suffix
  resource_group_name = var.resource_group_name
  ttl                 = 3600
  record {
    value = azurerm_app_service_certificate_order.cert_order[each.key].domain_verification_token
  }

  for_each = var.ingresses
}

# # App Service Certificate Stored in Key Vault
# resource "azurerm_app_service_certificate" "app_cert" {
#   name                = "app-cert-${each.key}"
#   resource_group_name = var.resource_group_name
#   location            = var.location
#   certificate_order_id = azurerm_app_service_certificate_order.cert_order[each.key].id
#   key_vault_secret_name = "cert-secret-${each.key}"

#   for_each = var.ingresses
# }



# Application Gateway
resource "azurerm_application_gateway" "app_gateway" {
  name                = "example-app-gateway"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "app-gateway-ip-config"
    subnet_id = azurerm_subnet.lb.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }
  
  # frontend_port {
  #   name = "http-port"
  #   port = 80
  # }

  # Assign v4 public IP
  frontend_ip_configuration {
    name                 = "app-gateway-frontend-v4"
    public_ip_address_id = azurerm_public_ip.lb_v4.id
  }

  dynamic "ssl_certificate" {
    for_each = var.ingresses
    iterator = each

    content {
      name = "app-service-certificate-${each.key}"
      key_vault_secret_id = azurerm_app_service_certificate_order.cert_order[each.key].certificates[0].key_vault_secret_name
    }
  }

  dynamic "http_listener" {
    for_each = var.ingresses
    iterator = each

    content {
      name = "https-listener-${each.key}"
      frontend_ip_configuration_name = "app-gateway-frontend-v4"
      frontend_port_name = "https-port"
      host_name = "${each.key}.${var.dns_suffix}"
      protocol = "Https"
      require_sni = true
      ssl_certificate_name = "app-service-certificate-${each.key}"
    }
  }

  # ssl_certificate {
  #   name        = "app-service-certificate"
  #   key_vault_secret_id = azurerm_app_service_certificate.app_cert.key_vault_secret_id
  # }

  # http_listener {
  #   name                           = "https-listener"
  #   frontend_ip_configuration_name = "app-gateway-frontend-ip"
  #   frontend_port_name             = "https-port"
  #   protocol                       = "Https"
  #   ssl_certificate_name           = "app-service-certificate"
  # }
  # http_listener {
  #   name                           = "http-listener-v4"
  #   frontend_ip_configuration_name = "app-gateway-frontend-v4"
  #   frontend_port_name             = "http-port"
  #   protocol                       = "Http"
  # }

  backend_address_pool {
    name = "backend-pool"
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  request_routing_rule {
    name                       = "http-routing-rule-v4"
    priority = 1
    rule_type                  = "Basic"
    http_listener_name         = "http-listener-v4"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings"
  }
}

# Data Source for Client Configuration
data "azurerm_client_config" "current" {}
