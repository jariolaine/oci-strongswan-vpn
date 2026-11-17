output "tun_1_ip" {
  value = oci_core_ipsec_connection_tunnel_management.tun_1.vpn_ip
}

output "tun_2_ip" {
  value = oci_core_ipsec_connection_tunnel_management.tun_2.vpn_ip
}

# Output values read from the provider after Terraform apply. These confirm
# the managed tunnel routing configuration but do not prove BGP is ESTABLISHED.
output "ipsec_connection_id" {
  value = oci_core_ipsec.ipsec_connection.id
}

output "tun_1_id" {
  value = oci_core_ipsec_connection_tunnel_management.tun_1.tunnel_id
}

output "tun_2_id" {
  value = oci_core_ipsec_connection_tunnel_management.tun_2.tunnel_id
}

output "tun_1_routing" {
  value = oci_core_ipsec_connection_tunnel_management.tun_1.routing
}

output "tun_2_routing" {
  value = oci_core_ipsec_connection_tunnel_management.tun_2.routing
}

output "tun_1_bgp_state" {
  value = try(oci_core_ipsec_connection_tunnel_management.tun_1.bgp_session_info[0].bgp_state, null)
}

output "tun_2_bgp_state" {
  value = try(oci_core_ipsec_connection_tunnel_management.tun_2.bgp_session_info[0].bgp_state, null)
}
