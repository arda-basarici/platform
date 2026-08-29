#!/bin/sh
# Cloudflare's IPv4 egress ranges are pinned in three places, each for its own
# reason (a plan reproducible offline, a firewall that never changes without a
# deliberate edit): box/Caddyfile `trusted_proxies`, box/firewall.sh
# CF_RANGES_V4, terraform/stacks/leave-impact-prod/variables.tf
# cloudflare_ipv4_ranges. A copy that lags the others admits a different edge
# at one origin — an outage that looks like flakiness, with no error anywhere.
# This script is the check: the three lists must be identical, and with
# --published also identical to https://www.cloudflare.com/ips-v4.
#   sh scripts/check-cf-ranges.sh              # ci, every push: the copies agree
#   sh scripts/check-cf-ranges.sh --published  # weekly: the copies match Cloudflare
# Exit 1 on any difference, with the diff. A difference against the published
# list is the refresh trigger: update all three, plan, deploy the box files.
set -eu
cd "$(dirname "$0")/.."

caddy=$(grep -E '^[[:space:]]*trusted_proxies static ' box/Caddyfile | sed 's/.*trusted_proxies static //' | tr -s ' \t' '\n' | grep . | sort)
firewall=$(grep -E '^CF_RANGES_V4=' box/firewall.sh | sed 's/^CF_RANGES_V4="//; s/"$//' | tr ' ' '\n' | grep . | sort)
terraform=$(awk '/^variable "cloudflare_ipv4_ranges"/,/^}/' terraform/stacks/leave-impact-prod/variables.tf | grep -oE '"[0-9./]+"' | tr -d '"' | sort)

count() { printf '%s\n' "$1" | grep -c .; }
echo "pinned: box/Caddyfile $(count "$caddy") · box/firewall.sh $(count "$firewall") · variables.tf $(count "$terraform")"

status=0
compare() { # compare <label> <list>: against the Caddyfile's copy
    if [ "$caddy" = "$2" ]; then
        echo "PASS  $1 matches box/Caddyfile"
    else
        echo "FAIL  $1 differs from box/Caddyfile:"
        printf '%s\n' "$caddy" > "/tmp/cf-caddy.$$"
        printf '%s\n' "$2" > "/tmp/cf-other.$$"
        diff "/tmp/cf-caddy.$$" "/tmp/cf-other.$$" || true
        rm -f "/tmp/cf-caddy.$$" "/tmp/cf-other.$$"
        status=1
    fi
}
compare "box/firewall.sh" "$firewall"
compare "variables.tf" "$terraform"

if [ "${1:-}" = "--published" ]; then
    published=$(curl -fsS https://www.cloudflare.com/ips-v4 | tr -d '\r' | grep . | sort)
    echo "published: cloudflare.com/ips-v4 $(count "$published")"
    compare "the published list" "$published"
fi

[ "$(count "$caddy")" -gt 0 ] || { echo "FAIL  no ranges extracted from box/Caddyfile"; status=1; }
exit $status
