#!/usr/bin/env bash
# Validate the live OCI IPSec tunnel BGP mode and report BGP session state.
# Requires Terraform, Python 3, OCI CLI, and configured OCI credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

if ! command -v terraform >/dev/null 2>&1; then
  echo 'Terraform CLI was not found on PATH.' >&2
  exit 1
fi

if ! command -v oci >/dev/null 2>&1; then
  echo 'OCI CLI was not found on PATH.' >&2
  exit 1
fi

ipsec_id="$(tf_output ipsec_connection_id)"

for n in 1 2; do
  tunnel_id="$(tf_output "tun_${n}_id")"
  printf '\n=== OCI tunnel %s ===\n' "$n"
  # Unlike Terraform outputs, this checks the OCI API live. The get endpoint
  # does not expose the pre-shared secret.
  oci network ip-sec-tunnel get \
    --ipsc-id "$ipsec_id" \
    --tunnel-id "$tunnel_id" \
    --output json | python3 -c '
import json
import sys

obj = json.load(sys.stdin).get("data") or {}
bgp = obj.get("bgp-session-info") or {}
routing = obj.get("routing", "UNKNOWN")
print("routing:             ", routing)
print("IPSec status:        ", obj.get("status", "UNKNOWN"))
print("BGP state:           ", bgp.get("bgp-state", "UNKNOWN"))
print("Customer BGP ASN:    ", bgp.get("customer-bgp-asn", "UNKNOWN"))
print("Customer interface:  ", bgp.get("customer-interface-ip", "UNKNOWN"))
print("Oracle interface:    ", bgp.get("oracle-interface-ip", "UNKNOWN"))
if routing != "BGP":
    print("ERROR: OCI tunnel routing is not BGP", file=sys.stderr)
    sys.exit(2)
if bgp.get("bgp-state") != "UP":
    print("NOTE: Tunnel routing is BGP but the BGP session is not UP", file=sys.stderr)
'
done
