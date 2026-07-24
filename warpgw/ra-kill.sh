#!/usr/bin/env bash
# ==============================================================================
# ra-kill.sh -- launcher for the scapy-based RA-kill daemon (ra-kill.py).
# ------------------------------------------------------------------------------
# The actual logic lives in ra-kill.py (L2-unicast a RouterLifetime=0 RA to each
# gateway client's MAC, so Wi-Fi / sleepy devices reliably drop their IPv6
# default route). This thin wrapper only locates a python3 that has scapy and
# execs it, so warpgw-ctl.sh / launchd can invoke it uniformly as
# "/bin/bash ra-kill.sh" without hardcoding a python path.
# ==============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for py in "$(command -v python3 2>/dev/null)" \
          /opt/homebrew/bin/python3 \
          /usr/local/bin/python3 \
          /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  [ -n "$py" ] && [ -x "$py" ] && "$py" -c "import scapy" >/dev/null 2>&1 \
    && exec "$py" "$DIR/ra-kill.py"
done

echo "[ra-kill] no python3 with scapy found; install it with:  python3 -m pip install scapy" >&2
exit 1
