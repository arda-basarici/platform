#!/bin/sh
# The acceptance checklist for a host built by site.yml — every section of
# box/README.md read back from the running host (DESIGN, "Step 4 rulings").
# Runs ON the host as root:
#   ansible -i inventory/local.yml all -b -m script -a verify.sh
# Each line is PASS or FAIL with what was seen; exit 1 if anything failed.
# Not covered here: the from-the-internet check (the bare IP must time out on
# 443 from the workstation), run by hand — it cannot prove itself from inside.

set -u
fails=0
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1: expected [$2], got [$3]"; fails=$((fails+1)); fi
}

# --- Hardening
sshd_eff=$(sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication) ' | sort | tr '\n' ' ')
check "sshd key-only, no root"  "kbdinteractiveauthentication no passwordauthentication no permitrootlogin no " "$sshd_eff"
check "ufw active"              "Status: active" "$(ufw status | head -1)"
check "ufw default deny in"     "deny" "$(ufw status verbose | sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p')"
check "ufw allows only 22"      "22/tcp" "$(ufw status | awk '$2=="ALLOW" {print $1}' | sed 's/ (v6)//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "apt-daily timers armed"  "2" "$(systemctl list-timers 'apt-daily*' --all --no-legend | grep -c apt-daily)"

# --- Docker
check "docker engine"           "0" "$(docker info >/dev/null 2>&1; echo $?)"
check "compose plugin"          "0" "$(docker compose version >/dev/null 2>&1; echo $?)"
check "web network"             "web" "$(docker network ls --filter name=^web$ --format '{{.Name}}')"

# --- Origin firewall
check "box-firewall enabled"    "enabled" "$(systemctl is-enabled box-firewall.service 2>/dev/null)"
check "box-firewall applied"    "active"  "$(systemctl is-active box-firewall.service 2>/dev/null)"
uplink=$(ip route show default | awk '{print $5; exit}')
check "DOCKER-USER: 443 from Cloudflare" "15" "$(iptables -S DOCKER-USER | grep -- "--ctorigdstport 443" | grep -- "-j RETURN" | grep -c -- "-i $uplink ")"
check "DOCKER-USER: drop the rest"       "1"  "$(iptables -S DOCKER-USER | grep -c -- "^-A DOCKER-USER -i $uplink -j DROP$")"

# --- Proxy: Caddy answers every hostname over the installed cert; the
# upstream is absent by design on a bare host, so 502 is the pass.
check "certs installed (key 0600)" "600" "$(stat -c %a /etc/platform/box/certs/ardabasarici.dev.key 2>/dev/null)"
check "only caddy publishes a port" "box-proxy-caddy-1" "$(docker ps --format '{{.Names}} {{.Ports}}' | grep -- '->' | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"
for host in steamlens.ardabasarici.dev hr.ardabasarici.dev hr-w1.ardabasarici.dev; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host:443:127.0.0.1" "https://$host/" 2>/dev/null)
    case "$code" in 200|502) echo "PASS  caddy serves $host ($code)";; *) echo "FAIL  caddy serves $host: got [$code]"; fails=$((fails+1));; esac
done

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
