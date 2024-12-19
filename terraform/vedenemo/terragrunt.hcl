# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

include "root" {
  path = find_in_parent_folders("terragrunt_includes.hcl")
}

dependency "dns_prod_eun" {
  config_path = "../prod-eun/dns"
}

dependency "dns_user_flokli" {
  config_path = "../user-flokli/dns"
}

inputs  = {
  ns_delegations = {
    "prod-eun" = dependency.dns_prod_eun.outputs.name_servers
    "flokli" = dependency.dns_user_flokli.outputs.name_servers
  }
}
