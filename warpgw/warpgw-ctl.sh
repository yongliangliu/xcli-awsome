#!/usr/bin/env bash
# ==============================================================================
# warpgw-ctl.sh -- WARP transparent gateway control script (invoked by xcli warpgw <cmd>)
# ------------------------------------------------------------------------------
# Lets any device that uses this Mac as its gateway (TV / phone / computer / ...)
# forward its traffic through this Mac out to Cloudflare WARP.
# Three parts are toggled together by this script:
#   1) IPv4 forwarding         sysctl net.inet.ip.forwarding=1
#   2) pf rules warpshare.pf   NAT to WARP + MSS clamping + DNS anti-poisoning (block local resolvers)
#   3) RA-kill daemon ra-kill.sh  uses Python/scapy to L2-unicast a RouterLifetime=0 RA
#                                 to each gateway client's MAC, dropping its IPv6 default route
#
# Commands: up | down | restart | status | install | uninstall | logs
#   up/down/restart/install/uninstall require root (xcli invokes them via sudo)
# ==============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_RULES="$DIR/warpshare.pf"
RAKILL="$DIR/ra-kill.sh"
PIDFILE="$DIR/.rakill.pid"
LOG="$DIR/rakill.log"
PLIST_LABEL="com.warpshare.gateway"
PLIST="/Library/LaunchDaemons/${PLIST_LABEL}.plist"

# --- Key parameters (must match ra-kill.sh / warpshare.pf) ---
LAN_IF="en0"
WARP_IF="utun0"

# --- Colors ---
c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_bad(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_dim(){ printf '\033[2m%s\033[0m\n' "$*"; }
c_hd(){ printf '\033[1;36m%s\033[0m\n' "$*"; }

CMD="${1:-}"

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    c_bad "This operation requires root, please run:  sudo xcli warpgw $CMD"
    exit 1
  fi
}

# --- locate a python3 that has scapy ---
find_py(){
  local p
  for p in "$(command -v python3 2>/dev/null)" \
           /opt/homebrew/bin/python3 \
           /usr/local/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
    [ -n "$p" ] && [ -x "$p" ] && "$p" -c "import scapy" >/dev/null 2>&1 && { echo "$p"; return 0; }
  done
  return 1
}

# --- ensure python3 + scapy are present, auto-install scapy if missing ---
ensure_scapy(){
  if find_py >/dev/null; then c_ok "python3+scapy : $(find_py)"; return 0; fi
  c_dim "scapy not found -> attempting: python3 -m pip install scapy ..."
  local py run_user
  py="$(command -v python3 2>/dev/null)" || py="/usr/local/bin/python3"
  run_user="${SUDO_USER:-$(id -un)}"
  if sudo -u "$run_user" "$py" -m pip install --user scapy 2>/dev/null; then
    find_py >/dev/null && { c_ok "scapy installed ($(find_py))"; return 0; }
  fi
  c_bad "scapy not installed. Install manually: python3 -m pip install scapy"
  exit 1
}

# --- optional local DNS cache: install/configure/start dnsmasq (non-fatal on failure) ---
find_brew(){
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { echo "$b"; return 0; }; done
  return 1
}
ensure_dnsmasq(){
  local brew run_user conf_src conf_dst
  brew="$(find_brew)" || { c_dim "dnsmasq       : skipped (Homebrew not found; optional DNS cache)"; return 0; }
  run_user="${SUDO_USER:-$(id -un)}"
  conf_src="$DIR/dnsmasq.conf"
  conf_dst="$("$brew" --prefix)/etc/dnsmasq.conf"
  # install if missing (brew refuses to run as root -> run as the invoking user)
  if ! [ -x "$("$brew" --prefix)/opt/dnsmasq/sbin/dnsmasq" ] && ! command -v dnsmasq >/dev/null 2>&1; then
    c_dim "dnsmasq not found -> attempting: brew install dnsmasq ..."
    sudo -u "$run_user" "$brew" install dnsmasq >/dev/null 2>&1 || { c_dim "dnsmasq       : brew install failed (optional, skipped)"; return 0; }
  fi
  # deploy our config if repo copy exists and differs
  if [ -f "$conf_src" ] && ! cmp -s "$conf_src" "$conf_dst" 2>/dev/null; then
    cp "$conf_src" "$conf_dst" && c_ok "dnsmasq config deployed -> $conf_dst"
  fi
  # (re)start as root service so it can bind :53
  if "$brew" services restart dnsmasq >/dev/null 2>&1; then
    c_ok "dnsmasq       : running (local DNS cache on ${LAN_IF}:53)"
  else
    c_dim "dnsmasq       : failed to start (optional; try: sudo brew services restart dnsmasq)"
  fi
}

check_prereq(){
  [ -f "$PF_RULES" ] || { c_bad "pf rules not found: $PF_RULES"; exit 1; }
  [ -f "$RAKILL" ]   || { c_bad "RA-kill not found: $RAKILL"; exit 1; }
  find_py >/dev/null || { c_bad "python3+scapy not found. Run: sudo xcli warpgw install  (or: python3 -m pip install scapy)"; exit 1; }
}

# --- RA-kill process helpers ---
rakill_pid(){ pgrep -f "[r]a-kill\.py" 2>/dev/null | head -1; }

start_rakill(){
  if [ -n "$(rakill_pid)" ]; then
    c_dim "RA-kill already running (pid $(rakill_pid))"
    return 0
  fi
  nohup /bin/bash "$RAKILL" >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 1
  if [ -n "$(rakill_pid)" ]; then c_ok "RA-kill started (pid $(rakill_pid))"; else c_bad "RA-kill failed to start, see $LOG"; fi
}

stop_rakill(){
  local p; p="$(rakill_pid)"
  pkill -f "[r]a-kill\.py" 2>/dev/null
  pkill -f "[r]a-kill\.sh" 2>/dev/null
  sleep 1
  if [ -n "$p" ]; then c_ok "RA-kill stopped"; else c_dim "RA-kill not running"; fi
  rm -f "$PIDFILE"
}

# --- Apply / restore each part ---
apply_gateway(){
  sysctl -w net.inet.ip.forwarding=1 >/dev/null && c_ok "IPv4 forwarding enabled"
  if pfctl -E -f "$PF_RULES" >/dev/null 2>&1; then c_ok "pf rules loaded (NAT + DNS anti-poisoning)"; else c_bad "pf load failed"; fi
  start_rakill
}

restore_gateway(){
  stop_rakill
  pfctl -f /etc/pf.conf >/dev/null 2>&1 && c_ok "pf restored to system default"
  sysctl -w net.inet.ip.forwarding=0 >/dev/null && c_ok "IPv4 forwarding disabled"
}

# --- Client onboarding help (auto-fills this Mac's real gateway IP to avoid mistakes) ---
client_help(){
  local gw net eg
  gw="$(ipconfig getifaddr "$LAN_IF" 2>/dev/null)"
  net="${gw%.*}"; eg="${net:+${net}.150}"
  c_hd "> How to connect a client (set this on the device you want proxied: TV / phone / computer)"
  echo   "  Switch the device Wi-Fi to [Manual / Static IP] and fill in:"
  printf '    - Router / Gateway : \033[1;33m%s\033[0m  <- THIS Mac, the critical one (do NOT use the router %s!)\n' "${gw:-<this host ${LAN_IF} address>}" "${net:-192.168.x}.1"
  echo   "    - Subnet Mask      : 255.255.255.0"
  echo   "    - IP Address       : an unused address in the same subnet (e.g. ${eg:-192.168.x.150})"
  echo   "    - DNS              : 1.1.1.1 (do NOT use auto/router, otherwise DNS bypasses the Mac and gets poisoned)"
  c_dim  "  Once set, the device is handled automatically; IPv6 leaks are suppressed within seconds. To revert: switch back to [Automatic (DHCP)]."
}

# ==============================================================================
case "$CMD" in

  up|start)
    need_root; check_prereq
    c_hd "> Starting WARP transparent gateway"
    apply_gateway
    echo; c_dim "Note: this is temporary and is lost after a Mac reboot. For auto-start on boot run: sudo xcli warpgw install"
    echo; client_help
    ;;

  down|stop)
    need_root
    c_hd "# Stopping and restoring WARP transparent gateway"
    if [ -f "$PLIST" ]; then c_dim "Auto-start is installed; consider using instead: sudo xcli warpgw uninstall"; fi
    restore_gateway
    echo; c_dim "To fully revert a client device: switch its gateway/DNS back to [Automatic (DHCP)]."
    ;;

  restart)
    need_root; check_prereq
    c_hd "~ Restarting WARP transparent gateway"
    restore_gateway; echo; apply_gateway
    ;;

  __run)
    # Invoked by launchd: apply forwarding+pf first, then run RA-kill in the foreground
    # (if it exits, launchd relaunches it).
    sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1
    pfctl -E -f "$PF_RULES" >/dev/null 2>&1
    exec /bin/bash "$RAKILL"
    ;;

  install)
    need_root
    c_hd "* Installing auto-start on boot (launchd: $PLIST_LABEL)"
    ensure_scapy            # auto-install python3/scapy if missing
    ensure_dnsmasq          # auto-install/start optional local DNS cache
    check_prereq
    cat >"$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>          <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DIR}/warpgw-ctl.sh</string>
        <string>__run</string>
    </array>
    <key>RunAtLoad</key>      <true/>
    <key>KeepAlive</key>      <true/>
    <key>StandardOutPath</key>  <string>${LOG}</string>
    <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
PLISTEOF
    chmod 644 "$PLIST"
    stop_rakill
    launchctl unload "$PLIST" 2>/dev/null
    if launchctl load -w "$PLIST" 2>/dev/null; then
      c_ok "Installed and started; will auto-restore on boot"
    else
      c_bad "launchctl load failed"
    fi
    sleep 1; bash "$DIR/warpgw-ctl.sh" status
    ;;

  uninstall)
    need_root
    c_hd "* Uninstalling auto-start on boot"
    if [ -f "$PLIST" ]; then
      launchctl unload "$PLIST" 2>/dev/null && c_ok "launchd job unloaded"
      rm -f "$PLIST" && c_ok "removed $PLIST"
    else
      c_dim "launchd job not installed"
    fi
    restore_gateway
    ;;

  logs)
    [ -f "$LOG" ] && tail -n 30 "$LOG" || c_dim "no logs yet ($LOG)"
    ;;

  status)
    c_hd "WARP transparent gateway status"
    fwd=$(sysctl -n net.inet.ip.forwarding 2>/dev/null)
    [ "$fwd" = "1" ] && c_ok "IPv4 forwarding : on" || c_bad "IPv4 forwarding : off"
    if [ "$(id -u)" -ne 0 ]; then
      c_dim "pf rules        : (needs sudo to view, use: sudo xcli warpgw status)"
    elif pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
      if pfctl -s nat 2>/dev/null | grep -q "nat on ${WARP_IF}"; then c_ok "pf rules        : loaded (NAT to WARP + DNS anti-poisoning)"; else c_bad "pf rules        : pf enabled but gateway NAT rule not found"; fi
    else c_bad "pf rules        : pf not enabled"; fi
    if find_py >/dev/null; then c_ok "python3+scapy   : $(find_py)"; else c_bad "python3+scapy   : not found (run: python3 -m pip install scapy)"; fi
    p="$(rakill_pid)"; [ -n "$p" ] && c_ok "RA-kill daemon  : running (pid $p)" || c_bad "RA-kill daemon  : not running"
    if [ -f "$PLIST" ]; then c_ok "Auto-start      : installed (launchd)"; else c_dim "Auto-start      : not installed (temporary mode, lost on reboot)"; fi
    ifconfig "$WARP_IF" >/dev/null 2>&1 && c_ok "WARP interface  : $WARP_IF online" || c_bad "WARP interface  : $WARP_IF missing (WARP not connected?)"
    if pgrep -x dnsmasq >/dev/null 2>&1; then c_ok "dnsmasq cache   : running (clients may use this Mac as DNS)"; else c_dim "dnsmasq cache   : not running (optional; installed by: sudo xcli warpgw install)"; fi
    echo; client_help
    ;;

  *)
    cat <<EOF
Usage: xcli warpgw <command>
  up          Start the transparent gateway (temporary, lost on reboot; use install to persist)  [needs sudo]
  down        Stop and restore (forwarding / pf / RA-kill all reverted)                           [needs sudo]
  restart     Restart                                                                             [needs sudo]
  status      Show current status (pf item needs sudo to be visible)
  install     Install as auto-start on boot (launchd); auto-installs scapy + dnsmasq if missing   [needs sudo]
  uninstall   Uninstall auto-start and stop                                                       [needs sudo]
  logs        Show RA-kill logs
EOF
    echo; client_help
    exit 1;;
esac
