#!/bin/bash
# Restrict Docker-published web ports (80/443) to Cloudflare source IPs.
#
# Docker inserts its own iptables rules (DOCKER/DOCKER-USER chains) that bypass
# UFW entirely, so the "Cloudflare-only" rule in setup.sh does NOT apply to
# container-published ports. The only place Docker honors for filtering
# forwarded traffic is the DOCKER-USER chain — so the restriction lives here.
#
# Scoped to the public interface only: inter-container traffic (app->mysql,
# nginx->fpm) arrives on docker bridge interfaces and is unaffected.
#
# Idempotent. Run at boot after docker via docker-cloudflare-firewall.service.

set -euo pipefail

# Cloudflare IPv4 — keep in sync with setup.sh (https://www.cloudflare.com/ips-v4)
CF_IPV4=(
  173.245.48.0/20
  103.21.244.0/22
  103.22.200.0/22
  103.31.4.0/22
  141.101.64.0/18
  108.162.192.0/18
  190.93.240.0/20
  188.114.96.0/20
  197.234.240.0/22
  198.41.128.0/17
  162.158.0.0/15
  104.16.0.0/13
  104.24.0.0/14
  172.64.0.0/13
  131.0.72.0/22
)

# Cloudflare IPv6 (https://www.cloudflare.com/ips-v6) — Docker also publishes on [::]
CF_IPV6=(
  2400:cb00::/32
  2606:4700::/32
  2803:f800::/32
  2405:b500::/32
  2405:8100::/32
  2a06:98c0::/29
  2c0f:f248::/32
)

PUB_IF=$(ip route show default | awk '/default/{print $5; exit}')
if [ -z "$PUB_IF" ]; then
  echo "FATAL: could not determine public interface" >&2
  exit 1
fi
echo "Public interface: $PUB_IF"

apply() {
  local ipt="$1" set="$2" family="$3"; shift 3
  local ranges=("$@")

  ipset create "$set" hash:net $family -exist
  ipset flush "$set"
  for ip in "${ranges[@]}"; do ipset add "$set" "$ip" -exist; done

  # Remove any prior copy of our rule (idempotent re-run), then insert at top
  while $ipt -D DOCKER-USER -i "$PUB_IF" -p tcp -m multiport --dports 80,443 \
        -m set ! --match-set "$set" src -j DROP -m comment --comment "cf-only" 2>/dev/null; do :; done
  $ipt -I DOCKER-USER -i "$PUB_IF" -p tcp -m multiport --dports 80,443 \
        -m set ! --match-set "$set" src -j DROP -m comment --comment "cf-only"
  echo "$ipt: 80/443 on $PUB_IF restricted to $set"
}

apply iptables  cf4 ""              "${CF_IPV4[@]}"
apply ip6tables cf6 "family inet6"  "${CF_IPV6[@]}"

echo "Done — non-Cloudflare traffic to published 80/443 is now dropped."
