#!/usr/bin/env bash
# ==============================================================================
# ra-kill.sh -- IPv6 leak suppressor (ipv6toolkit / ra6 edition, no Python)
# ------------------------------------------------------------------------------
# Periodically sends a spoofed Router Advertisement with Router Lifetime = 0
# (impersonating the REAL router's link-local address) to the all-nodes group
# ff02::1, so every device on the segment drops the router-advertised IPv6
# default route and falls back to clean IPv4 via this Mac -> WARP. This closes
# the IPv6 leak that would otherwise let dual-stack sites (YouTube etc.) go out
# directly over IPv6 and get poisoned by the GFW.
#
# Uses SI6 Networks' IPv6 Toolkit `ra6` (brew install ipv6toolkit) -- a mature,
# actively-maintained, macOS-native tool -- instead of hand-rolled packet
# crafting. ra6 already handles building/sending the RA; this script only:
#   1) resolves the real router link-local address (native netstat, no hardcode)
#   2) loops, re-reading it each cycle so it follows a network change
#
# Scope: the RA goes to all-nodes, so EVERY device on the LAN drops its IPv6
# default route (they keep working over IPv4). This is intentional and is the
# simplest, most robust way to guarantee no device leaks over IPv6.
#
# Needs root (raw/BPF). Started by warpgw-ctl.sh (up / __run via launchd).
# ==============================================================================
set -u

IFACE="${RAKILL_IFACE:-en0}"
INTERVAL="${RAKILL_INTERVAL:-2}"     # seconds between RAs (must be faster than the router's periodic RA)
FALLBACK_ROUTER_LL="fe80::1"         # used only if the default route cannot be read

# --- locate ra6 (lives in sbin, not always on PATH under launchd) ---
RA6=""
for p in "$(command -v ra6 2>/dev/null)" /usr/local/sbin/ra6 /opt/homebrew/sbin/ra6; do
  [ -n "$p" ] && [ -x "$p" ] && { RA6="$p"; break; }
done
if [ -z "$RA6" ]; then
  echo "[ra-kill] ra6 not found (install: brew install ipv6toolkit)" >&2
  exit 1
fi

# --- read the real IPv6 default gateway link-local address (strip %zone) ---
read_router_ll(){
  local ll
  ll=$(netstat -rn -f inet6 2>/dev/null | awk '$1=="default" && $2 ~ /^fe80/{print $2}' | head -1)
  ll="${ll%%\%*}"
  echo "${ll:-$FALLBACK_ROUTER_LL}"
}

echo "[ra-kill] ra6=$RA6 iface=$IFACE interval=${INTERVAL}s"
n=0
while :; do
  rll="$(read_router_ll)"
  # -s <router LL>: spoof the real router as source (hosts key the default route on this)
  # -t 0          : Router Lifetime = 0 -> receivers drop that router's IPv6 default route
  # -d ff02::1    : all-nodes (every device on the segment)
  "$RA6" -i "$IFACE" -s "$rll" -t 0 -d ff02::1 >/dev/null 2>&1
  n=$((n + 1))
  if [ $((n % 30)) -eq 1 ]; then
    echo "[ra-kill] round $n: router_ll=$rll (RA lifetime=0 -> all-nodes)"
  fi
  sleep "$INTERVAL"
done
