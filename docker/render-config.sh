#!/usr/bin/env bash
# Render BIRD and swanctl from the Terraform-generated Docker environment.
# Separated from the entrypoint so configuration can be tested without a VPN.
set -Eeuo pipefail
umask 077

readonly SNAT_BIN="${VPN_SNAT_BIN:-/usr/local/bin/snat.sh}"
readonly BIRD_TEMPLATE="${VPN_BIRD_TEMPLATE:-/tmp/bird.conf.template}"
readonly SWANCTL_TEMPLATE="${VPN_SWANCTL_TEMPLATE:-/tmp/swanctl.conf.template}"
readonly BIRD_CONFIG="${VPN_BIRD_CONFIG:-/etc/bird/bird.conf}"
readonly SWANCTL_CONFIG="${VPN_SWANCTL_CONFIG:-/etc/swanctl/swanctl.conf}"

fail() { printf '[render] ERROR: %s\n' "$*" >&2; exit 1; }

valid_ipv4() {
  local octet
  local -a octets
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$1"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

valid_cidr() {
  local address="${1%/*}" prefix="${1##*/}"
  [[ "$1" == */* ]] || return 1
  valid_ipv4 "$address" || return 1
  [[ "$prefix" =~ ^([0-9]|[12][0-9]|3[012])$ ]]
}

valid_asn() {
  local num="$1"
  [[ "$num" =~ ^[0-9]{1,10}$ ]] || return 1
  num="$((10#$num))"
  (( num >= 1 && num <= 4294967295 ))
}

normalize_cidrs() {
  local label="$1" input="$2" optional="$3" cidr
  local -a cidrs=()
  [[ "$input" != *$'\n'* && "$input" != *$'\r'* ]] || fail "$label must be one line"
  input="${input//,/ }"
  input="${input//;/ }"
  read -r -a cidrs <<< "$input"
  if (( ${#cidrs[@]} == 0 )); then
    [[ "$optional" == yes ]] || fail "$label requires at least one IPv4 CIDR"
    printf ''
    return
  fi
  for cidr in "${cidrs[@]}"; do
    valid_cidr "$cidr" || fail "Invalid IPv4 CIDR in $label: '$cidr'"
  done
  local joined
  printf -v joined '%s, ' "${cidrs[@]}"
  printf '%s' "${joined%, }"
}

for key in VPN_OCI_TUN_1_PSK VPN_OCI_TUN_2_PSK VPN_OCI_TUN_1_IP VPN_OCI_TUN_2_IP \
  VPN_CPE_IDENTIFIER VPN_OCI_TUN_1_LOCAL_CIDR VPN_OCI_TUN_1_PEER_CIDR \
  VPN_OCI_TUN_2_LOCAL_CIDR VPN_OCI_TUN_2_PEER_CIDR VPN_ROUTER_PREFIXES; do
  [[ -n "${!key:-}" ]] || fail "Missing required $key"
done
[[ -f "$BIRD_TEMPLATE" && -f "$SWANCTL_TEMPLATE" ]] || fail 'Required configuration template missing'
[[ -x "$SNAT_BIN" ]] || fail "Missing SNAT helper: $SNAT_BIN"

for key in VPN_OCI_TUN_1_IP VPN_OCI_TUN_2_IP; do
  valid_ipv4 "${!key}" || fail "Invalid IPv4 endpoint in $key"
done
for key in VPN_OCI_TUN_1_LOCAL_CIDR VPN_OCI_TUN_1_PEER_CIDR \
  VPN_OCI_TUN_2_LOCAL_CIDR VPN_OCI_TUN_2_PEER_CIDR; do
  valid_cidr "${!key}" || fail "Invalid inside IPv4 CIDR in $key"
done
[[ "$VPN_OCI_TUN_1_IP" != "$VPN_OCI_TUN_2_IP" ]] || fail 'The OCI tunnel endpoints must be different'
[[ "$VPN_CPE_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || \
  fail 'VPN_CPE_IDENTIFIER must be a hostname without the @ prefix or whitespace'

for key in VPN_OCI_TUN_1_PSK VPN_OCI_TUN_2_PSK; do
  [[ "${!key}" != REPLACE_WITH_* ]] || fail "Placeholder value in $key"
done

readonly ROUTER_ASN="${VPN_ROUTER_ASN:-64555}"
readonly OCI_ASN="${VPN_OCI_ASN:-31898}"
valid_asn "$ROUTER_ASN" || fail 'Invalid VPN_ROUTER_ASN'
valid_asn "$OCI_ASN" || fail 'Invalid VPN_OCI_ASN'

ROUTER_PREFIX_LIST="$(normalize_cidrs VPN_ROUTER_PREFIXES "$VPN_ROUTER_PREFIXES" no)" || \
  fail 'Invalid VPN_ROUTER_PREFIXES'
REJECT_PREFIX_LIST="$(normalize_cidrs VPN_OCI_REJECT_PREFIXES "${VPN_OCI_REJECT_PREFIXES:-}" yes)" || \
  fail 'Invalid VPN_OCI_REJECT_PREFIXES'
readonly ROUTER_PREFIX_LIST REJECT_PREFIX_LIST
# Conservative import behavior: OCI must opt in explicitly to advertise a
# default route; otherwise the default could redirect IKE/public traffic.
case "${VPN_OCI_ACCEPT_DEFAULT_ROUTE:-false}" in
  true) OCI_DEFAULT_ROUTE_RULE='' ;;
  false) OCI_DEFAULT_ROUTE_RULE='if net = 0.0.0.0/0 then reject;' ;;
  *) fail 'VPN_OCI_ACCEPT_DEFAULT_ROUTE must be true or false' ;;
esac

readonly XFRM_ID1="${VPN_XFRM_IF_ID_1:-1001}" XFRM_ID2="${VPN_XFRM_IF_ID_2:-1002}"
for id in "$XFRM_ID1" "$XFRM_ID2"; do
  [[ "$id" =~ ^[1-9][0-9]{0,9}$ ]] && (( id <= 4294967295 )) || \
    fail 'XFRM interface IDs must be positive decimal 32-bit integers'
done
(( XFRM_ID1 != XFRM_ID2 )) || fail 'XFRM IDs must differ'
readonly XFRM_MTU="${VPN_XFRM_MTU:-1360}"
[[ "$XFRM_MTU" =~ ^[0-9]{3,4}$ ]] && (( 10#$XFRM_MTU >= 576 && 10#$XFRM_MTU <= 1500 )) || \
  fail 'VPN_XFRM_MTU must be between 576 and 1500'
OCI_REJECT_RULE=''
if [[ -n "$REJECT_PREFIX_LIST" ]]; then
  OCI_REJECT_RULE="if net ~ [ $REJECT_PREFIX_LIST ] then reject;"
fi

readonly PEER1="${VPN_OCI_TUN_1_PEER_CIDR%%/*}"
readonly PEER2="${VPN_OCI_TUN_2_PEER_CIDR%%/*}"
readonly LOCAL1="${VPN_OCI_TUN_1_LOCAL_CIDR%%/*}"
readonly LOCAL2="${VPN_OCI_TUN_2_LOCAL_CIDR%%/*}"
if [[ -n "${VPN_ROUTER_IP:-}" ]]; then
  ROUTER_IP="$VPN_ROUTER_IP"
else
  ROUTER_IP="$("$SNAT_BIN" source-ip)" || fail 'Cannot detect host router IP; set VPN_ROUTER_IP or check routing to the OCI VPN peer'
fi
valid_ipv4 "$ROUTER_IP" || fail 'Invalid VPN_ROUTER_IP'
printf '[render] Router ID: %s\n' "$ROUTER_IP" >&2

# Never pass plaintext PSKs on a command line or store them in the image.
PSK1_B64="$(printf '%s' "$VPN_OCI_TUN_1_PSK" | base64 -w 0)"
PSK2_B64="$(printf '%s' "$VPN_OCI_TUN_2_PSK" | base64 -w 0)"

# sed replacements contain only validated IPv4/hostname/CIDR/numeric tokens
# or base64 values (none have sed replacement metacharacters for '|').
mkdir -p "$(dirname "$BIRD_CONFIG")" "$(dirname "$SWANCTL_CONFIG")"
bird_tmp="$(mktemp "$(dirname "$BIRD_CONFIG")/.bird.conf.XXXXXX")"
swan_tmp="$(mktemp "$(dirname "$SWANCTL_CONFIG")/.swanctl.conf.XXXXXX")"
trap 'rm -f "$bird_tmp" "$swan_tmp"' EXIT

sed \
  -e "s|\${VPN_ROUTER_IP}|${ROUTER_IP}|g" \
  -e "s|\${VPN_OCI_TUN_1_PEER_IP}|${PEER1}|g" \
  -e "s|\${VPN_OCI_TUN_1_LOCAL_IP}|${LOCAL1}|g" \
  -e "s|\${VPN_OCI_TUN_2_PEER_IP}|${PEER2}|g" \
  -e "s|\${VPN_OCI_TUN_2_LOCAL_IP}|${LOCAL2}|g" \
  -e "s|\${VPN_ROUTER_ASN}|${ROUTER_ASN}|g" \
  -e "s|\${VPN_OCI_ASN}|${OCI_ASN}|g" \
  -e "s|\${VPN_ROUTER_PREFIXES}|${ROUTER_PREFIX_LIST}|g" \
  -e "s|\${VPN_OCI_REJECT_RULE}|${OCI_REJECT_RULE}|g" \
  -e "s|\${VPN_OCI_DEFAULT_ROUTE_RULE}|${OCI_DEFAULT_ROUTE_RULE}|g" \
  "$BIRD_TEMPLATE" > "$bird_tmp"

sed \
  -e "s|\${VPN_OCI_TUN_1_IP}|${VPN_OCI_TUN_1_IP}|g" \
  -e "s|\${VPN_OCI_TUN_2_IP}|${VPN_OCI_TUN_2_IP}|g" \
  -e "s|\${VPN_CPE_IDENTIFIER}|${VPN_CPE_IDENTIFIER}|g" \
  -e "s|\${VPN_XFRM_IF_ID_1}|${XFRM_ID1}|g" \
  -e "s|\${VPN_XFRM_IF_ID_2}|${XFRM_ID2}|g" \
  -e "s|\${VPN_OCI_TUN_1_LOCAL_CIDR}|${VPN_OCI_TUN_1_LOCAL_CIDR}|g" \
  -e "s|\${VPN_OCI_TUN_1_PEER_CIDR}|${VPN_OCI_TUN_1_PEER_CIDR}|g" \
  -e "s|\${VPN_OCI_TUN_2_LOCAL_CIDR}|${VPN_OCI_TUN_2_LOCAL_CIDR}|g" \
  -e "s|\${VPN_OCI_TUN_2_PEER_CIDR}|${VPN_OCI_TUN_2_PEER_CIDR}|g" \
  -e "s|\${VPN_OCI_TUN_1_PSK_B64}|${PSK1_B64}|g" \
  -e "s|\${VPN_OCI_TUN_2_PSK_B64}|${PSK2_B64}|g" \
  "$SWANCTL_TEMPLATE" > "$swan_tmp"

if grep -Eq '\$\{VPN_[A-Za-z0-9_]+\}' "$bird_tmp" "$swan_tmp"; then
  fail 'Unresolved VPN template placeholder'
fi
chmod 0600 "$bird_tmp" "$swan_tmp"
mv -f "$bird_tmp" "$BIRD_CONFIG"
mv -f "$swan_tmp" "$SWANCTL_CONFIG"

unset PSK1_B64 PSK2_B64
printf '[render] Wrote BIRD and root-only swanctl configuration\n' >&2
