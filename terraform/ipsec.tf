provider "oci" {
  tenancy_ocid        = var.tenancy_ocid
  region              = var.region
}

data "oci_core_cpe_device_shapes" "all_cpe_shapes" {
}

locals {
  # Iterate through the shapes and extract the ID where the vendor matches "other" (case-insensitive)
  strongswan_shape_id = [
    for shape in data.oci_core_cpe_device_shapes.all_cpe_shapes.cpe_device_shapes :
    shape.cpe_device_shape_id if length(regexall("(?i)other", shape.cpe_device_info[0].vendor)) > 0
  ][0]
}

resource "oci_core_cpe" "cpe" {
  compartment_id      = var.compartment_ocid
  display_name        = var.cpe_display_name
  ip_address          = var.cpe_ip
  cpe_device_shape_id = local.strongswan_shape_id
}

resource "oci_core_ipsec_connection_tunnel_management" "tun_1" {
  ipsec_id  = oci_core_ipsec.ipsec_connection.id
  tunnel_id = data.oci_core_ipsec_connection_tunnels.ipsec_connection_tunnels.ip_sec_connection_tunnels[0].id
  #Optional
  display_name        = var.tun_1_display_name
  # OCI initializes tunnels with static routing; explicitly switch this
  # individual tunnel to BGP and configure its BGP inside interface settings.
  routing             = "BGP"
  shared_secret       = var.tun_1_shared_secret
  ike_version         = "V2"
  oracle_can_initiate = "RESPONDER_ONLY"
  dpd_config {
    dpd_mode          = "RESPOND_ONLY"
  }
  bgp_session_info {
    customer_bgp_asn      = var.customer_bgp_asn
    customer_interface_ip = var.tun_1_customer_interface_ip
    oracle_interface_ip   = var.tun_1_oracle_interface_ip
  }
  phase_one_details {
    is_custom_phase_one_config = false
  }
  phase_two_details {
    is_custom_phase_two_config = false
    is_pfs_enabled = true
  }
}

resource "oci_core_ipsec_connection_tunnel_management" "tun_2" {
  ipsec_id  = oci_core_ipsec.ipsec_connection.id
  tunnel_id = data.oci_core_ipsec_connection_tunnels.ipsec_connection_tunnels.ip_sec_connection_tunnels[1].id
  #Optional
  display_name        = var.tun_2_display_name
  # OCI initializes tunnels with static routing; explicitly switch this
  # individual tunnel to BGP and configure its BGP inside interface settings.
  routing             = "BGP"
  shared_secret       = var.tun_2_shared_secret
  ike_version         = "V2"
  oracle_can_initiate = "RESPONDER_ONLY"
  dpd_config {
    dpd_mode          = "RESPOND_ONLY"
  }
  bgp_session_info {
    customer_bgp_asn      = var.customer_bgp_asn
    customer_interface_ip = var.tun_2_customer_interface_ip
    oracle_interface_ip   = var.tun_2_oracle_interface_ip
  }

  phase_one_details {
    is_custom_phase_one_config = false
  }
  phase_two_details {
    is_custom_phase_two_config = false
    is_pfs_enabled = true
  }
}

resource "oci_core_ipsec" "ipsec_connection" {
  #Required
  compartment_id            = var.compartment_ocid
  cpe_id                    = oci_core_cpe.cpe.id
  drg_id                    = var.drg_ocid
  # Required when first creating an IPSec connection (the tunnels initially
  # default to STATIC); ignored once both tunnels use BGP via management above.
  static_routes             = [var.router_prefix]
  #Optional
  cpe_local_identifier_type = "HOSTNAME"
  cpe_local_identifier      = var.cpe_identifier
  display_name              = var.ipsec_display_name
}

data "oci_core_ipsec_connections" "ipsec_connections" {
  #Required
  compartment_id = var.compartment_ocid
  #Optional
  cpe_id = oci_core_cpe.cpe.id
  drg_id = var.drg_ocid
}

data "oci_core_ipsec_connection_tunnels" "ipsec_connection_tunnels" {
  ipsec_id = oci_core_ipsec.ipsec_connection.id
}
