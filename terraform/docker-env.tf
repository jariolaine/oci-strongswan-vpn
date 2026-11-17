# Render a Docker Compose .env from native Terraform input variables and
# the two OCI VPN tunnel endpoints returned by the OCI provider.
# This resource is created only after the referenced tunnel resources exist.
locals {
  docker_env_vars = {
    VPN_OCI_TUN_1_IP         = oci_core_ipsec_connection_tunnel_management.tun_1.vpn_ip
    VPN_OCI_TUN_2_IP         = oci_core_ipsec_connection_tunnel_management.tun_2.vpn_ip
    VPN_OCI_TUN_1_PSK        = var.tun_1_shared_secret
    VPN_OCI_TUN_2_PSK        = var.tun_2_shared_secret
    VPN_CPE_IDENTIFIER       = var.cpe_identifier
    VPN_ROUTER_ASN           = var.customer_bgp_asn
    VPN_ROUTER_PREFIXES      = var.router_prefix
    VPN_OCI_ASN              = var.oci_bgp_asn
    VPN_OCI_REJECT_PREFIXES  = var.oci_reject_prefixes
    VPN_OCI_ACCEPT_DEFAULT_ROUTE = tostring(var.oci_accept_default_route)
    VPN_OCI_TUN_1_LOCAL_CIDR = var.tun_1_customer_interface_ip
    VPN_OCI_TUN_1_PEER_CIDR  = var.tun_1_oracle_interface_ip
    VPN_OCI_TUN_2_LOCAL_CIDR = var.tun_2_customer_interface_ip
    VPN_OCI_TUN_2_PEER_CIDR  = var.tun_2_oracle_interface_ip
    VPN_ROUTER_IP            = var.router_ip
    VPN_XFRM_IF_ID_1         = tostring(var.xfrm_if_id_1)
    VPN_XFRM_IF_ID_2         = tostring(var.xfrm_if_id_2)
    VPN_XFRM_MTU             = tostring(var.xfrm_mtu)
    VPN_SNAT_ENABLED         = tostring(var.snat_enabled)
    VPN_SNAT_NETWORKS        = var.snat_networks
    VPN_SNAT_EXTRA_NETWORKS  = var.snat_extra_networks
    VPN_SNAT_SOURCE_IP       = var.snat_source_ip
    VPN_SNAT_PORTS           = var.snat_ports
    VPN_SNAT_REFRESH_SECONDS = tostring(var.snat_refresh_seconds)
  }
}

resource "local_sensitive_file" "docker_env" {
  lifecycle {
    precondition {
      condition     = var.xfrm_if_id_1 != var.xfrm_if_id_2
      error_message = "XFRM interface IDs for the two tunnels must differ."
    }
    precondition {
      condition     = alltrue([for value in values(local.docker_env_vars) : length(regexall("[\r\n]", value)) == 0])
      error_message = "Docker .env values must not contain newline or carriage-return characters."
    }
  }
  filename        = "${path.module}/../.env"
  file_permission = "0600"
  content = templatefile("${path.module}/docker.env.tftpl", {
    environment = local.docker_env_vars
  })

}
