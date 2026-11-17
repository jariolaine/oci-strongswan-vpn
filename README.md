# StrongSwan OCI Site-to-Site VPN

A Linux/Docker Site-to-Site IPsec gateway for **two OCI tunnels**, managed by
**strongSwan `swanctl`/VICI**, with **BIRD 2 BGP**, **Linux XFRM interfaces** and
optional **dynamic Docker-network TCP SNAT**. Terraform creates the OCI CPE and
IPsec connection and generates Docker Compose's environment file. The Compose
project is `vpn`, with the service named `strongswan`.

## Contents

- [Getting started](#getting-started): prerequisites, deployment and teardown
- [Architecture and internals](#architecture-and-internals): XFRM, IKE/IPsec, SNAT and BGP
- [Operations and diagnosis](#operations-and-diagnosis): runtime checks and live OCI BGP verification

## Getting started

### VPN host requirements

- **Linux kernel 4.19+** with XFRM-interface support and **`iproute2` 5.1+** (needed for `ip link add ... type xfrm`).
  On modular kernels, `sudo modprobe xfrm_interface` may be required.
- Docker Engine with Linux host networking; `NET_ADMIN` is granted to the
  container. Run only on a trusted host: this grants management of **host**
  networking and firewall state.
- Host IPv4 forwarding: `sudo sysctl -w net.ipv4.ip_forward=1` if routing
  containers. Persist it using your host's sysctl configuration.
- Two reachable OCI VPN public endpoints. Allow UDP **500 and 4500**;
  forced UDP encapsulation makes **4500 mandatory**. Allow TCP **179**
  over both encrypted inside links.
- Non-overlapping host, Docker and OCI CIDRs; allow Docker-to-XFRM forwarding
  and related replies in the host firewall. The SNAT script **does not** add
  FORWARD-chain permissions.
- Source prefixes advertised by BGP must actually exist in BIRD/kernel
  routing, and OCI must have matching return paths in its DRG route tables.
- If Docker uses nftables instead of iptables, review integration and custom
  forwarding rules; the included SNAT script specifically uses `iptables`.

The public OCI tunnel endpoint traffic must continue to use the **host's
underlay**, not a route learned through the VPN. The XFRM setup refuses to
proceed when the endpoint route resolves over an `xfrm-*` or `vti*` interface.

### Terraform and deployment

1. Copy `terraform/terraform.tfvars.example` to
   `terraform/terraform.tfvars` and fill in OCI, BGP, CPE and inside-tunnel
   settings. Do not commit the `.tfvars` file.
2. Supply the two pre-shared keys using Terraform's native environment
   variables (not in Git):

   ```bash
   export TF_VAR_tun_1_shared_secret='first-secret'
   export TF_VAR_tun_2_shared_secret='second-secret'
   ```

3. Inspect and apply Terraform:

   ```bash
   terraform -chdir=terraform init
   terraform -chdir=terraform validate
   terraform -chdir=terraform plan
   terraform -chdir=terraform apply
   ```

   The native `templatefile()`/`local_sensitive_file` mechanism writes root
   `.env` (mode `0600`), including the actual OCI public tunnel IP addresses,
   PSKs, BGP settings, XFRM IDs, and SNAT options.

   Review Terraform outputs with:

   ```bash
   terraform -chdir=terraform output
   ```

   Outputs include `tun_1_ip` / `tun_2_ip`, the IPSec connection ID,
   tunnel IDs, `tun_1_routing` / `tun_2_routing`, and
   `tun_1_bgp_state` / `tun_2_bgp_state`. These values come from
   Terraform's **last state refresh**; they are **not a live BGP health
   check**. See the OCI CLI verification helper under *Operations and diagnosis*.

4. Build and start the container:

   ```bash
   docker compose build --pull --no-cache strongswan
   docker compose up -d --force-recreate --no-deps strongswan
   docker compose logs --tail=120 strongswan
   ```

Changes to the generated `.env` are not loaded into an already-running
container; recreate it to apply them. A container-only update does not
require modifying OCI resources. Always review `terraform plan` separately
before making OCI infrastructure changes.

### Teardown and cleanup

To stop only the Linux VPN runtime, run:

```bash
docker compose down
```

If you also intend to delete the **OCI CPE and IPSec connection managed by
this Terraform state**, first inspect the destruction plan:

```bash
terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
```

These commands are destructive: ensure the connection is no longer needed,
back up important Terraform state, and review the plan before confirming.
Provide the usual Terraform inputs, including the PSKs, when prompted.
The existing DRG is an input, not a resource this project creates. Terraform
also manages the local root `.env`, which may be removed on destroy. Execute
`docker compose down` first, while `.env` still exists.

After an unclean container stop, inspect `ip -d link show xfrm-oci1` and
`ip -d link show xfrm-oci2`. Delete a leftover interface only after verifying
that it belongs to this VPN; never automatically remove unrelated host links.

## Architecture and internals

### Network design

- `charon` runs without systemd; `swanctl` loads credentials before initiating
  the two IKEv2 connections.
- Each CHILD_SA uses `if_id_in = if_id_out` to bind IPsec policy to one Linux
  XFRM interface.
- `xfrm-oci1` (ID `1001`) and `xfrm-oci2` (ID `1002`) are created **before**
  loading the connections. Interfaces stay up across CHILD_SA/IKE_SA rekeys.
- BIRD peers with OCI across each interface's connected inside tunnel network,
  imports BGP routes subject to the default-route guard and optional CIDR
  exclusions, and advertises only configured local prefixes. Its keepalive
  and hold timers are **60/180 seconds**, graceful-restart awareness is enabled,
  and its per-peer import/export route limits are **100, action `warn`**
  (warning logs only; additional routes are not discarded).
- With SNAT enabled, traffic from selected Docker networks, going **out of an
  XFRM interface** on selected TCP destination ports, is translated to a
  configured or auto-detected VPN host source address.
- Before changing host networking, `render-config.sh` checks required inputs,
  addresses, prefix lists, XFRM settings and placeholder PSKs; it Base64-encodes
  the PSKs and atomically writes mode-`0600` runtime BIRD and `swanctl`
  configuration files. The entrypoint checks BIRD syntax with `bird -p`
  before creating XFRM links or starting `charon`.

#### IKE/IPsec characteristics

Both tunnels use IKEv2 with PSK authentication and explicitly configured
proposals: **`aes256-sha384-ecp384`** for IKE and
**`aes256gcm16-modp1536`** for ESP (AES-256-GCM with Phase 2 PFS group 5).
The configured IKE/CHILD rekey times are **8 hours / 1 hour**.

- `encap = yes` forces UDP-encapsulated ESP: **UDP 4500 is required**, along
  with UDP 500 for IKE negotiation. Native ESP forwarding is not normally
  required for this forced-encapsulation setup.
- `mobike = no` disables MOBIKE.
- The local daemon runs DPD checks with `dpd_delay = 30s` and the CHILD_SA
  `dpd_action = restart`; OCI is configured with `dpd_mode = RESPOND_ONLY`.
- The customer gateway initiates with `start_action = start`, while OCI is
  configured `oracle_can_initiate = RESPONDER_ONLY`. This is a deliberate
  customer-initiated tunnel arrangement.

The project intentionally **does not configure PMTUD or TCP MSS clamping**.
The XFRM interface MTU defaults to `1360`, reducing the risk of oversized
inner packets. It does not replace PMTUD or guarantee fragmentation-free
operation.

### Configure dynamic SNAT

Terraform inputs and their defaults:

| Terraform input | Default | Effect |
| --- | --- | --- |
| `snat_enabled` | `true` | Enable SNAT reconciler; `false` cleans up its rules |
| `snat_networks` | `"auto"` | Discover connected routes on `docker0` and `br-*` |
| `snat_extra_networks` | `""` | Extra CIDRs for custom bridge interfaces |
| `snat_ports` | `"1522"` | Comma/space/semicolon-separated **TCP** destination ports |
| `snat_source_ip` | `""` | SNAT source IP, blank for host underlay source |
| `snat_refresh_seconds` | `15` | Seconds between network/rule checks |
| `router_prefix` | required | BGP-advertised source prefix (must cover SNAT address) |

Example `terraform/terraform.tfvars` settings:

```hcl
snat_networks        = "auto"
snat_extra_networks  = "172.25.0.0/16"
snat_ports           = "443,1522,8443"
snat_source_ip       = ""  # Detect host's source IP toward OCI tunnel peer
```

The script uses a dedicated `STRONGSWAN_SNAT` iptables NAT chain and installs
one jump per destination port in `POSTROUTING` for `-o xfrm-oci+`. It does
not translate traffic to unrelated internet routes. Docker bridge CIDRs can
change; the watcher updates the rules. The source IP must be routable back
from OCI through a BGP-advertised prefix.

Inspect the configuration and counters:

```bash
docker compose exec strongswan /usr/local/bin/snat.sh show
sudo iptables -t nat -S STRONGSWAN_SNAT
sudo iptables -t nat -S POSTROUTING | grep STRONGSWAN_SNAT
```

### BGP routing safeguards

- `router_prefix` controls what BIRD may advertise, provided the route
  exists in the routing table.
- `oci_reject_prefixes = ""` (default) means **no explicit CIDR exclusion**.
- Independently, `oci_accept_default_route = false` rejects `0.0.0.0/0`
  learned from OCI; this helps prevent losing the host's underlay IKE path.
  Set it to `true` only if you have deliberately engineered a safe route for
  both public OCI tunnel endpoints. **Rejecting only `0.0.0.0/0` does not
  prevent a more-specific imported route from covering an endpoint**.
  Ensure underlay reachability with appropriate host routes and/or BGP import
  filtering; `xfrm.sh` checks the endpoint routes at startup, not continuously.
- OCI's `oci_core_ipsec` resource is created with
  `static_routes = [var.router_prefix]` because the initial IPSec tunnel
  configuration uses static routing. This is a **creation-time placeholder**:
  the tunnel-management resources switch **both tunnels to BGP**, at which
  point OCI ignores that static-route list. BIRD advertises the prefix.
- Do not assume imported routes alone enable OCI transit to particular
  services. OCI DRG route tables and return routing must also be configured.

`VPN_XFRM_IF_ID_1`, `VPN_XFRM_IF_ID_2` and `VPN_XFRM_MTU` are generated
from `xfrm_if_id_1`, `xfrm_if_id_2` and `xfrm_mtu` Terraform variables.
Both interface IDs must be distinct and free on the host.

`router_ip` (rendered as `VPN_ROUTER_IP`) optionally pins BIRD's router ID.
If empty, the renderer calls `snat.sh source-ip`: this uses the
`snat_source_ip` override if set, otherwise the `src` address from
`ip -4 route get` toward the first OCI public tunnel endpoint. The resolved
address is used both as the **BIRD router ID** and as `krt_prefsrc` on
BIRD-installed kernel routes; it must be appropriate for the host and route
advertisements.

## Operations and diagnosis

```bash
# Both configured IKE/CHILD connections and SAs
docker compose exec strongswan swanctl --list-conns
docker compose exec strongswan swanctl --list-sas

# BGP and imported/exported routes
docker compose exec strongswan birdc show protocols all
docker compose exec strongswan birdc show route export oci_tun1
docker compose exec strongswan birdc show route export oci_tun2

# XFRM interfaces and policy state (host network namespace)
ip -d link show xfrm-oci1
ip -d link show xfrm-oci2
ip xfrm state
ip xfrm policy

# Verify underlay and data routing
ip -4 route get <OCI_VPN_PUBLIC_IP>
ip -4 route get <REMOTE_PRIVATE_IP>

# Check link availability without requiring a live IKE session
docker compose exec strongswan /usr/local/bin/xfrm.sh check
```

The container's health check verifies that VICI, BIRD and XFRM interfaces
respond. Compose runs it every **30 seconds** after a **45-second start period**.
It does **not** prove that OCI's IPsec or BGP sessions are established.

### Verify OCI BGP status via the live API

The included `scripts/verify-oci-bgp.sh` gets the IPSec connection and tunnel
IDs from **Terraform outputs**, then calls `oci network ip-sec-tunnel get`
for **both** tunnels. It prints the live OCI tunnel routing mode, IPSec
status, BGP state, customer ASN and inside peer addresses.

Requirements: Terraform CLI with access to this project's initialized state,
Python 3, the **OCI CLI** (`oci`) and configured OCI CLI credentials/permissions
to read the IPSec tunnels. From the repository root:

```bash
./scripts/verify-oci-bgp.sh
```

The script resolves the Terraform directory relative to its own location, so
you can also invoke it from elsewhere using its absolute path.

The script **fails** when OCI reports a routing mode other than `BGP` or when
an API call fails. It **prints a warning but does not fail** when OCI reports
a BGP state other than `UP`; check the reported state explicitly.

### Interface ownership and crash recovery

`docker/xfrm.sh` only deletes links it recorded as created by the running
container, and verifies their XFRM interface IDs before deletion. A restart
of the **same container** after interruption can clean its old owned links.
When the container is **replaced** after an unclean stop, the old filesystem
ownership marker is gone; it deliberately refuses to take over a preexisting
`xfrm-oci1`/`xfrm-oci2`. Inspect `ip -d link show` and remove only confirmed
stale interfaces manually on the host (for example, `sudo ip link del dev xfrm-oci1`). Never blindly delete
unrelated host VPN devices.

The archive does not include a runnable automated test suite; these checks require a real deployment.

## Security and repository hygiene

Do not commit `.env`, `terraform/terraform.tfvars`, Terraform state, saved
plans or backups containing PSKs. Commit `terraform/.terraform.lock.hcl`.
Terraform sensitive inputs and `local_sensitive_file` may still store secrets
in **Terraform state**; protect that state. The runtime `swanctl.conf`
contains Base64-encoded (not encrypted) secrets but is written mode `0600`.
The PSKs are also present in Docker container environment metadata accessible
to Docker administrators. Restrict host and Docker daemon access.

## Authoritative references

- [strongSwan route-based VPN/XFRM](https://docs.strongswan.org/docs/latest/features/routeBasedVpn.html)
- [strongSwan swanctl configuration](https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html)
- [BIRD 2 documentation](https://bird.nic.cz/doc/bird-2.18.html).

## License
The repository includes an MIT `LICENSE.txt`. Preserve any third-party
license notices when incorporating external code.
