#!/usr/bin/env bash
# Configure two XFRM interfaces and supervise charon/VICI, BIRD 2 and SNAT.
set -Eeuo pipefail

readonly SNAT_BIN=/usr/local/bin/snat.sh
readonly XFRM_BIN=/usr/local/bin/xfrm.sh
readonly RENDER_BIN=/usr/local/bin/render-config.sh
readonly CHARON_BIN=/usr/lib/ipsec/charon
CHARON_PID=''
BIRD_PID=''
SNAT_PID=''
CLEANED_UP=0

log() { printf '[entrypoint] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

cleanup() {
  (( CLEANED_UP == 0 )) || return 0
  CLEANED_UP=1
  # Stop the watcher first so it can't re-install rules while we remove them.
  if [[ -n "$SNAT_PID" ]]; then
    kill "$SNAT_PID" 2>/dev/null || true
    wait "$SNAT_PID" 2>/dev/null || true
  fi
  if [[ -n "$BIRD_PID" ]]; then
    kill "$BIRD_PID" 2>/dev/null || true
    wait "$BIRD_PID" 2>/dev/null || true
  fi
  if [[ -n "$CHARON_PID" ]]; then
    kill "$CHARON_PID" 2>/dev/null || true
    wait "$CHARON_PID" 2>/dev/null || true
  fi

  # XFRM interfaces are long-lived across CHILD_SA and IKE_SA rekeys.
  # The manager only deletes interfaces whose type and if_id match ours.
  "$XFRM_BIN" cleanup || log 'Could not clean up owned XFRM interfaces'
  "$SNAT_BIN" cleanup || log 'Could not clean up SNAT rules'
  log 'All managed processes stopped'
}

for program in swanctl bird birdc ip iptables sysctl sed awk base64 grep; do
  command -v "$program" >/dev/null 2>&1 || fail "Missing $program; rebuild the Docker image"
done
[[ -x "$CHARON_BIN" ]] || fail "Missing charon binary: $CHARON_BIN"
[[ -x "$RENDER_BIN" && -x "$SNAT_BIN" && -x "$XFRM_BIN" ]] || \
  fail 'One or more runtime scripts were not installed in the image'

# Validate rendered BIRD before touching IKE or host routes, and write
# swanctl secrets only to a root-only runtime file. No PSKs are passed on CLI.
"$RENDER_BIN"
unset VPN_OCI_TUN_1_PSK VPN_OCI_TUN_2_PSK
log 'Validating BIRD 2 configuration'
bird -p -c /etc/bird/bird.conf || fail 'BIRD rejected the generated configuration'

trap cleanup EXIT
trap 'exit 0' SIGTERM SIGINT

# Interfaces and their directly connected BGP peers must exist before
# loading CHILD_SAs. An XFRM if_id binds the SA to its named interface.
log 'Configuring host XFRM interfaces'
"$XFRM_BIN" setup || fail 'XFRM setup failed: check host kernel support and stale VTI interfaces'

if [[ "${VPN_SNAT_ENABLED:-true}" == true ]]; then
  [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || \
    fail 'Host IPv4 forwarding disabled: set net.ipv4.ip_forward=1 on the VPN host'
fi

log 'Starting charon in foreground mode (supervised)'
"$CHARON_BIN" &
CHARON_PID=$!

# Ensure the VICI socket is responsive before attempting swanctl commands.
ready=0
for ((attempt=1; attempt<=30; attempt++)); do
  if swanctl --stats >/dev/null 2>&1; then
    ready=1
    break
  fi
  kill -0 "$CHARON_PID" 2>/dev/null || fail 'charon exited before VICI became available'
  sleep 1
done
(( ready == 1 )) || fail 'VICI was not available after 30 checks; verify charon plugin loading'
# XFRM interfaces do not require an updown plugin. They remain allocated
# during CHILD_SA rekeys and temporary tunnel outages.

# swanctl --load-all loads connections first. Since start_action=start triggers
# initiation at load time, load the PSKs FIRST, then the connections.
log 'Loading IKE pre-shared keys via VICI'
swanctl --load-creds --noprompt || fail 'Could not load swanctl credentials'
log 'Loading and initiating both OCI tunnels'
swanctl --load-conns || fail 'Could not load swanctl connections'

if [[ "${VPN_SNAT_ENABLED:-true}" == true ]]; then
  log 'Starting dynamic Docker-network SNAT'
  "$SNAT_BIN" watch &
  SNAT_PID=$!
else
  log 'SNAT disabled; removing previously managed rules'
  "$SNAT_BIN" cleanup || fail 'SNAT cleanup failed'
fi

log 'Starting BIRD 2'
bird -f -c /etc/bird/bird.conf &
BIRD_PID=$!

# Exit (and let Docker's restart policy recover) if any required service dies.
# Do not exit merely because the OCI peer is temporarily unreachable.
pids=("$CHARON_PID" "$BIRD_PID")
[[ -z "$SNAT_PID" ]] || pids+=("$SNAT_PID")
set +e
wait -n "${pids[@]}"
exit_status=$?
set -e
fail "A managed service exited (exit status $exit_status); shutting down and allowing Docker to restart"
