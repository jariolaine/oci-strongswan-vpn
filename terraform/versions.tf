terraform {
  required_version = ">= 1.2.0"

  required_providers {
    oci = {
      source = "oracle/oci"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
