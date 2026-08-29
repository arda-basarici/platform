#!/bin/sh
# Origin firewall for Docker-published ports: only Cloudflare's edge may
# reach them. Runs from the platform checkout (/srv/platform/box/firewall.sh),
# applied once per boot by box-firewall.service beside it; re-runnable by hand.
#
# Why this layer exists: Docker-published ports bypass ufw — inbound IPv4 is
# DNAT'ed in PREROUTING and *forwarded* into the container, consulting the
# FORWARD chain (where Docker gives user rules first say via the DOCKER-USER
# hook) and never ufw's INPUT rules. This script owns that hook. The IPv6
# side is deliberately not mirrored with an allowance: the origin DNS record
# is v4-only, so Cloudflare never dials the box over v6, and the v6-published
# ports are served by docker-proxy (a host process) — host processes answer
# to INPUT, where ufw's default-deny covers them once 80/443 have no allow
# rules.
#
# Idempotent: flushes and rebuilds only the DOCKER-USER chains; safe to
# re-run any time. Lockout-safe by construction: DOCKER-USER sees only
# traffic forwarded into containers — ssh rides INPUT, which this never
# touches.

set -eu

IFACE="${IFACE:-eth0}"   # the box's uplink; a systemd drop-in overrides it on a host whose NIC is named differently

# Cloudflare's published IPv4 ranges (cloudflare.com/ips-v4, fetched
# 2026-08-10) — one of three pinned copies with the Caddyfile's
# trusted_proxies and the AWS stack's variables.tf; scripts/check-cf-ranges.sh
# keeps them identical in ci and compares them with the published list
# weekly. A drift alarm there is the refresh trigger: all three together.
CF_RANGES_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"

# Create-if-missing makes boot ordering a non-issue: whichever of Docker and
# this unit starts first, the other finds the chain and uses it (Docker only
# creates DOCKER-USER when absent and never flushes it).
iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER

# Replies to container-outbound connections arrive on the same interface —
# let established flows pass before any origin filtering.
iptables -A DOCKER-USER -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# Cloudflare -> origin 443. Matched on the *original* destination port: by
# FORWARD time the DNAT has already rewritten the packet's port, so a plain
# --dport would silently break the day the published mapping stops being
# 443:443. RETURN, not ACCEPT: the verdict stays with Docker's own chains.
for net in $CF_RANGES_V4; do
    iptables -A DOCKER-USER -i "$IFACE" -s "$net" -p tcp \
        -m conntrack --ctdir ORIGINAL --ctorigdstport 443 -j RETURN
done

# Everything else the internet sends at a container: dropped. Traffic on
# other interfaces (inter-container, container-outbound) falls through to
# Docker's own rules untouched.
iptables -A DOCKER-USER -i "$IFACE" -j DROP

# IPv6 mirror, belt-and-suspenders: today no container traffic is forwarded
# over v6 (no container has a v6 address), but if a future Docker default or
# compose change enables NAT66, these rules are already standing. No
# Cloudflare allowance — see the header.
ip6tables -N DOCKER-USER 2>/dev/null || true
ip6tables -F DOCKER-USER
ip6tables -A DOCKER-USER -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ip6tables -A DOCKER-USER -i "$IFACE" -j DROP

echo "DOCKER-USER firewall applied: 443 open to Cloudflare's ranges only"
