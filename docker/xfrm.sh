#!/usr/bin/env bash
# Create XFRM interfaces for two route-based OCI tunnels.
# Runs in the Docker host network namespace. Never delete foreign links.
set -Eeuo pipefail

readonly IF1=xfrm-oci1 IF2=xfrm-oci2
readonly OWNED_FILE="${VPN_XFRM_OWNED_FILE:-/run/strongswan-xfrm/owned}"
readonly MTU="${VPN_XFRM_MTU:-1360}"
readonly ID1="${VPN_XFRM_IF_ID_1:-1001}" ID2="${VPN_XFRM_IF_ID_2:-1002}"

log() { printf '[xfrm] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

valid_ipv4() {
  local -a parts
  local p
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<< "$1"
  (( ${#parts[@]} == 4 )) || return 1
  for p in "${parts[@]}"; do (( 10#$p <= 255 )) || return 1; done
}
valid_cidr() {
  [[ "$1" == */* ]] || return 1
  valid_ipv4 "${1%/*}" || return 1
  [[ "${1##*/}" =~ ^([0-9]|[12][0-9]|3[012])$ ]]
}

validate() {
  [[ "$MTU" =~ ^[0-9]{3,4}$ ]] && (( 10#$MTU >= 576 && 10#$MTU <= 1500 )) || \
    fail 'VPN_XFRM_MTU must be between 576 and 1500'
  local id key
  for id in "$ID1" "$ID2"; do
    [[ "$id" =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$id <= 4294967295 )) || \
      fail 'XFRM interface IDs must be positive decimal 32-bit integers'
  done
  (( 10#$ID1 != 10#$ID2 )) || fail 'The two XFRM interface IDs must differ'
  for key in VPN_OCI_TUN_1_IP VPN_OCI_TUN_2_IP \
    VPN_OCI_TUN_1_LOCAL_CIDR VPN_OCI_TUN_1_PEER_CIDR \
    VPN_OCI_TUN_2_LOCAL_CIDR VPN_OCI_TUN_2_PEER_CIDR; do
    [[ -n "${!key:-}" ]] || fail "Missing $key"
    if [[ "$key" == *_IP ]]; then
      valid_ipv4 "${!key}" || fail "Invalid $key"
    else
      valid_cidr "${!key}" || fail "Invalid $key"
    fi
  done
  [[ "$VPN_OCI_TUN_1_IP" != "$VPN_OCI_TUN_2_IP" ]] || fail 'Both public OCI VPN IPs are identical'
}

# iproute2 commonly prints the ID in hex; parse decimal or hex.
match_id() {
  local detail value expected="$2"
  detail="$(ip -d link show dev "$1" 2>/dev/null)" || return 1
  [[ "$detail" =~ xfrm[[:space:]]+if_id[[:space:]]+(0[xX][0-9a-fA-F]+|[0-9]+) ]] || return 1
  value="${BASH_REMATCH[1]}"
  if [[ "$value" == 0x* || "$value" == 0X* ]]; then
    (( value == expected ))
  else
    (( 10#$value == 10#$expected ))
  fi
}

# The OCI VPN public endpoints must remain reachable via the host underlay.
check_underlay() {
  local peer route dev
  for peer in "$VPN_OCI_TUN_1_IP" "$VPN_OCI_TUN_2_IP"; do
    route="$(ip -4 route get "$peer")" || fail "No underlay route to OCI endpoint $peer"
    dev="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route")"
    [[ -n "$dev" && "$dev" != xfrm-* && "$dev" != vti* && "$dev" != lo ]] || \
      fail "OCI endpoint $peer is routed into a VPN/non-underlay interface: $route"
  done
}

create_one() {
  local name="$1" id="$2" local_cidr="$3"
  if ip link show dev "$name" >/dev/null 2>&1; then
    # A previous container may have been killed before its cleanup trap ran.
    # Do NOT silently adopt or delete an interface in the host namespace.
    fail "$name already exists; inspect 'ip -d link show $name' and remove only if it belongs to this VPN"
  fi
  log "Creating $name with XFRM interface ID $id"
  ip link add "$name" type xfrm if_id "$id" || \
    fail "Failed creating $name (host needs Linux XFRM interface support)"
  # Record immediately, so cleanup can delete it if address/MTU setup fails.
  printf '%s %s\n' "$name" "$id" >> "$OWNED_FILE"
  # A /30 on-link address creates the directly connected route to OCI's
  # inside BGP neighbor without adding tunnel remote endpoints to the link.
  ip -4 addr replace "$local_cidr" dev "$name" || fail "Cannot address $name"
  ip link set dev "$name" mtu "$MTU" up || fail "Cannot activate $name"
}

setup() {
  validate
  # Underlay check before creating any interfaces; BIRD is not running yet.
  check_underlay
  for legacy in vti-oci1 vti-oci2; do
    if ip link show dev "$legacy" >/dev/null 2>&1; then
      fail "Old VTI $legacy remains; stop the legacy VPN and remove only confirmed stale interfaces"
    fi
  done
  mkdir -p -m 0700 "$(dirname "$OWNED_FILE")"
  if [[ -e "$OWNED_FILE" ]]; then
    # Same container restarted after SIGKILL: marker persisted in its FS.
    # Remove only links previously recorded by this container and with
    # matching interface IDs. A newly recreated container has no marker.
    log "Recovering interfaces from previous interrupted run"
    cleanup
  fi
  ( umask 077; : > "$OWNED_FILE" )
  create_one "$IF1" "$ID1" "$VPN_OCI_TUN_1_LOCAL_CIDR"
  create_one "$IF2" "$ID2" "$VPN_OCI_TUN_2_LOCAL_CIDR"
}

check() {
  validate
  match_id "$IF1" "$ID1" && match_id "$IF2" "$ID2" || \
    fail 'XFRM interface missing or interface ID mismatch'
  ip -4 addr show dev "$IF1" | grep -Fq "${VPN_OCI_TUN_1_LOCAL_CIDR%%/*}" || \
    fail "$IF1 missing inside address"
  ip -4 addr show dev "$IF2" | grep -Fq "${VPN_OCI_TUN_2_LOCAL_CIDR%%/*}" || \
    fail "$IF2 missing inside address"
}

cleanup() {
  if [[ ! -f "$OWNED_FILE" ]]; then
    log 'No owned XFRM interfaces to clean up'
    return 0
  fi
  local name id
  # Ownership is limited to interfaces created by THIS container process.
  while read -r name id; do
    case "$name:$id" in
      "$IF1:$ID1"|"$IF2:$ID2")
        if match_id "$name" "$id"; then
          ip link del dev "$name" || log "Could not delete $name"
        else
          log "Skipping $name: missing interface or non-matching ID"
        fi
        ;;
      *) log "Skipping unexpected ownership entry: $name" ;;
    esac
  done < "$OWNED_FILE"
  rm -f "$OWNED_FILE"
}

case "${1:-}" in
  setup) setup ;;
  check) check ;;
  cleanup) cleanup ;;
  *) fail 'Usage: xfrm.sh setup|check|cleanup' ;;
esac
