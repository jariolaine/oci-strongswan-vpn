# Terraform inputs come from native terraform.tfvars and/or TF_VAR_* shell variables.
# The Docker .env file is generated, never used as input to this configuration.

variable "tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID"
}

variable "region" {
  type        = string
  description = "OCI region (for example eu-frankfurt-1)"
}

variable "compartment_ocid" {
  type        = string
  description = "OCI compartment OCID"
}

variable "drg_ocid" {
  type        = string
  description = "Existing OCI Dynamic Routing Gateway (DRG) OCID."
}

variable "cpe_ip" {
  type        = string
  description = "CPE public IPv4 address"
}

variable "cpe_identifier" {
  type        = string
  description = "CPE IKE identity hostname; must match StrongSwan leftid"
}

variable "cpe_display_name" {
  type        = string
  description = "Name of the OCI CPE"
}

variable "ipsec_display_name" {
  type        = string
  description = "Name of the OCI IPSec connection"
}

variable "tun_1_display_name" {
  type        = string
  description = "Name of first VPN tunnel"
}

variable "tun_2_display_name" {
  type        = string
  description = "Name of second VPN tunnel"
}

variable "customer_bgp_asn" {
  type        = string
  description = "BGP ASN for the customer-side router"
}

variable "tun_1_customer_interface_ip" {
  type        = string
  description = "First tunnel local interface IPv4 CIDR"
}

variable "tun_1_oracle_interface_ip" {
  type        = string
  description = "First tunnel OCI interface IPv4 CIDR"
}

variable "tun_2_customer_interface_ip" {
  type        = string
  description = "Second tunnel local interface IPv4 CIDR"
}

variable "tun_2_oracle_interface_ip" {
  type        = string
  description = "Second tunnel OCI interface IPv4 CIDR"
}

variable "router_prefix" {
  type        = string
  description = "Source CIDR advertised by BIRD; static_routes is unused for BGP tunnels"
}

variable "tun_1_shared_secret" {
  type        = string
  description = "IPSec PSK for the first tunnel (provide as a native TF_VAR_ environment variable)"
  sensitive   = true
  nullable    = false
}

variable "tun_2_shared_secret" {
  type        = string
  description = "IPSec PSK for the second tunnel (provide as a native TF_VAR_ environment variable)"
  sensitive   = true
  nullable    = false
}

# Runtime-only options for the generated Docker Compose .env.
# These defaults preserve the v2.2 Compose behavior.
variable "oci_bgp_asn" {
  type        = string
  description = "OCI BGP ASN for BIRD"
  default     = "31898"
}

variable "oci_reject_prefixes" {
  type        = string
  description = "Optional OCI BGP import exclusions (comma-, semicolon- or whitespace-separated IPv4 CIDRs); empty disables exclusions"
  default     = ""
  nullable    = false
}

variable "router_ip" {
  type        = string
  description = "Optional BIRD router ID source IPv4; empty means auto-detect"
  default     = ""
}

variable "snat_enabled" {
  type        = bool
  description = "Enable dynamic Docker-network SNAT"
  default     = true
}

variable "snat_networks" {
  type        = string
  description = "Docker subnets to SNAT; auto discovers docker0 and br-*"
  default     = "auto"
}

variable "snat_extra_networks" {
  type        = string
  description = "Additional Docker CIDRs for SNAT"
  default     = ""
}

variable "snat_source_ip" {
  type        = string
  description = "Override SNAT source IP; empty means use detected host source"
  default     = ""
}

variable "snat_ports" {
  type        = string
  description = "Comma-, space- or semicolon-separated TCP destination ports for SNAT"
  default     = "1522"
}

variable "snat_refresh_seconds" {
  type        = number
  description = "Seconds between SNAT reconciliations"
  default     = 15
  validation {
    condition     = var.snat_refresh_seconds >= 1 && floor(var.snat_refresh_seconds) == var.snat_refresh_seconds
    error_message = "snat_refresh_seconds must be a positive integer."
  }
}

# XFRM interface IDs are local to the Linux host, not configured on OCI.
variable "xfrm_if_id_1" {
  type        = number
  description = "XFRM interface ID for the first tunnel"
  default     = 1001
  validation {
    condition     = var.xfrm_if_id_1 >= 1 && var.xfrm_if_id_1 <= 4294967295 && floor(var.xfrm_if_id_1) == var.xfrm_if_id_1
    error_message = "xfrm_if_id_1 must be an unsigned, nonzero 32-bit integer."
  }
}

variable "xfrm_if_id_2" {
  type        = number
  description = "XFRM interface ID for the second tunnel"
  default     = 1002
  validation {
    condition     = var.xfrm_if_id_2 >= 1 && var.xfrm_if_id_2 <= 4294967295 && floor(var.xfrm_if_id_2) == var.xfrm_if_id_2
    error_message = "xfrm_if_id_2 must be an unsigned, nonzero 32-bit integer."
  }
}

variable "xfrm_mtu" {
  type        = number
  description = "Inner MTU of both XFRM interfaces (not automatic PMTUD)"
  default     = 1360
  validation {
    condition     = var.xfrm_mtu >= 576 && var.xfrm_mtu <= 1500 && floor(var.xfrm_mtu) == var.xfrm_mtu
    error_message = "xfrm_mtu must be between 576 and 1500."
  }
}

variable "oci_accept_default_route" {
  type        = bool
  description = "Allow OCI BGP peers to advertise 0.0.0.0/0 (off by default to protect IKE reachability)"
  default     = false
}
