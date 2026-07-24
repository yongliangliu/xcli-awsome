#!/usr/bin/env python3
# ============================================================
# RA-kill (auto edition) -- make every device that "uses this host as its gateway"
# drop its IPv6 default route.
# ------------------------------------------------------------
# Impersonate the real router's link-local address and send an RA to the target
# device with Router Lifetime = 0 (drop the v6 default route) and RDNSS lifetime = 0
# (stop using the router-advertised v6 DNS), so the device falls back to clean IPv4
# via this Mac -> WARP.  L2-unicast to each device MAC (Ether(dst=mac)) so Wi-Fi /
# sleepy devices reliably receive it.  Fully auto-discovered; fully reversible.
#
# Start/stop (needs root):
#   sudo python3 ra-kill.py &
#   sudo pkill -f ra-kill.py
# ============================================================
import os
import re
import time
import threading
import ipaddress
import subprocess
from scapy.all import (Ether, IPv6, ICMPv6ND_RA, ICMPv6NDOptRDNSS,
                       sendp, sniff, get_if_hwaddr)

IFACE      = os.environ.get("RAKILL_IFACE", "en0")   # LAN interface
INTERVAL   = 2                                        # seconds; must be faster than the router's periodic RA
STICKY_TTL = 600                                      # seconds; once a device is seen, keep suppressing it this long
ALL_NODES  = "ff02::1"                                # target v6 address (all-nodes)
FALLBACK_ROUTER_LL = "fe80::1"                        # fallback source when the default route cannot be read

# ---- runtime shared state ----
_lock      = threading.Lock()
_router_ll = FALLBACK_ROUTER_LL      # the real router link-local address being impersonated
_rdnss     = [FALLBACK_ROUTER_LL]    # list of v6 DNS to be cleared (lifetime=0)


def norm_mac(m):
    """Normalize a MAC to zero-padded lowercase (arp and scapy formats differ)."""
    try:
        return ":".join(f"{int(x, 16):02x}" for x in m.split(":"))
    except Exception:
        return (m or "").lower()


def get_local_ipv4(iface):
    """Parse this host's IPv4 and its subnet CIDR from ifconfig."""
    out = subprocess.check_output(["ifconfig", iface]).decode()
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)", out)
    if not m:
        raise RuntimeError(f"{iface} has no IPv4 address")
    ip = m.group(1)
    prefix = bin(int(m.group(2), 16)).count("1")
    net = ipaddress.ip_network(f"{ip}/{prefix}", strict=False)
    return ip, net


def read_router_ll(iface):
    """Read the IPv6 default gateway's link-local address (the real router) from the routing table."""
    try:
        out = subprocess.check_output(
            ["netstat", "-rn", "-f", "inet6"], text=True)
    except Exception:
        return None
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] == "default" and f[1].startswith("fe80"):
            gw = f[1].split("%")[0]
            # prefer the default route on this LAN interface
            if f"%{iface}" in f[1] or iface in line:
                return gw
    # fallback: any fe80 default gateway
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] == "default" and f[1].startswith("fe80"):
            return f[1].split("%")[0]
    return None


MY_MAC = norm_mac(get_if_hwaddr(IFACE))
MY_IP, LAN_NET = get_local_ipv4(IFACE)


def is_local(ip):
    try:
        return ipaddress.ip_address(ip) in LAN_NET
    except ValueError:
        return False


def is_routable_remote(ip):
    """A genuine external peer (not in the local subnet, not multicast/broadcast/self)."""
    if is_local(ip):
        return False
    if ip.startswith(("224.", "239.", "255.")) or ip.endswith(".255"):
        return False
    return True


def ra_sniffer():
    """Lightweight sniff of real RAs to keep correcting router LL and RDNSS (icmp6 traffic is tiny)."""
    def handle(pkt):
        global _router_ll, _rdnss
        if ICMPv6ND_RA not in pkt or IPv6 not in pkt:
            return
        src = pkt[IPv6].src
        if not src.startswith("fe80"):
            return
        with _lock:
            _router_ll = src
            if ICMPv6NDOptRDNSS in pkt and pkt[ICMPv6NDOptRDNSS].dns:
                _rdnss = list(pkt[ICMPv6NDOptRDNSS].dns)
            else:
                _rdnss = [src]
    try:
        sniff(iface=IFACE, store=0, prn=handle, filter="icmp6")
    except Exception as e:
        print(f"[ra-kill] RA sniffer thread exited: {e}", flush=True)


def discover_gateway_clients():
    """Poll the pf state table for "local source + remote external" forwarded flows -> gateway client LAN IPs."""
    ips = set()
    try:
        out = subprocess.run(["pfctl", "-s", "states"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ips
    for line in out.splitlines():
        addrs = re.findall(r"(\d+\.\d+\.\d+\.\d+)", line)
        if not addrs:
            continue
        locals_ = [a for a in addrs if is_local(a) and a != MY_IP]
        remotes = [a for a in addrs if is_routable_remote(a)]
        if locals_ and remotes:
            ips.update(locals_)
    return ips


def arp_ip_to_mac():
    """Parse the arp table -> {IPv4: MAC}."""
    table = {}
    try:
        out = subprocess.run(["arp", "-an"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return table
    for ip, mac in re.findall(
            r"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]+)", out):
        table[ip] = norm_mac(mac)
    return table


def main():
    print(f"[ra-kill] iface={IFACE} my_mac={MY_MAC} my_ip={MY_IP} "
          f"lan={LAN_NET}", flush=True)
    rll = read_router_ll(IFACE)
    if rll:
        global _router_ll, _rdnss
        with _lock:
            _router_ll = rll
            _rdnss = [rll]
    print(f"[ra-kill] initial router LL={_router_ll} (will be corrected by RA sniffer)",
          flush=True)

    threading.Thread(target=ra_sniffer, daemon=True).start()

    seen = {}   # gateway client MAC -> timestamp last seen (sticky)
    n = 0
    while True:
        now = time.time()
        client_ips = discover_gateway_clients()
        arp = arp_ip_to_mac()

        # clients found this round -> refresh their timestamp
        for ip in client_ips:
            mac = arp.get(ip)
            if mac:
                seen[mac] = now
        # sticky: keep MACs seen within STICKY_TTL -- avoids missing IPv4-leaning
        # devices (e.g. iPhone) during IPv4 traffic gaps, which would let IPv6 leak recur
        seen = {m: ts for m, ts in seen.items() if now - ts <= STICKY_TTL}

        with _lock:
            src_ll = _router_ll
            dns = list(_rdnss) or [src_ll]

        for mac in seen:
            # RA sent to all-nodes, but L2-unicast to this device MAC -- only it receives it
            pkt = (Ether(dst=mac) /
                   IPv6(src=src_ll, dst=ALL_NODES) /
                   ICMPv6ND_RA(routerlifetime=0, reachabletime=0,
                               retranstimer=0) /
                   ICMPv6NDOptRDNSS(lifetime=0, dns=dns))
            sendp(pkt, iface=IFACE, verbose=0)

        n += 1
        if n % 10 == 1:
            print(f"[ra-kill] round {n}: router_ll={src_ll} rdnss={dns} "
                  f"active={len(client_ips)} targeted={len(seen)}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
