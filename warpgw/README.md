# warpgw -- WARP transparent gateway

Forward the traffic of **any device that "uses this Mac as its gateway"** (TV /
phone / computer / ...) through this Mac, at layer 3, out via Cloudflare WARP.
Core goal: let LAN devices that cannot tunnel on their own but need low latency
(typically SmartTube on Android TV) smoothly play 4K YouTube.

> This is an `xcli` domain. All actions are done through `xcli warpgw <command>`.

---

## Why a transparent gateway (instead of a normal proxy)

The first attempt used gost to give the TV an HTTP/SOCKS proxy, and **4K turned
into a slideshow**. Root cause:

- SmartTube uses Cronet and streams over **QUIC (UDP / HTTP3)**.
- Through a proxy, QUIC gets choked and falls back to TCP; round-trip latency
  climbs to ~300ms, too slow to feed the high-bitrate 4K buffer.

**Approach**: do not proxy at the application layer; forward at **layer 3 (IP
layer)** instead -- the device uses the Mac as its default gateway, and the Mac
uses `pf` to NAT packets into the WARP tunnel (`utun0`). This **preserves QUIC /
UDP as-is**, brings latency back to normal, and 4K plays smoothly.

But layer-3 forwarding exposes two "leak" problems, which are solved as well:

| Problem | Symptom | Fix |
|---------|---------|-----|
| **IPv6 leak** | The device has an IPv6 default route (from the router's RA), goes out over v6 directly, bypassing Mac/WARP, and gets poisoned by the GFW | `ra-kill.py` (Python/scapy): L2-unicasts a spoofed RA with `RouterLifetime=0` + `RDNSS lifetime=0` to each gateway client's MAC, reliably removing its v6 default route and DNS |
| **DNS poisoning** | The device uses a domestic DNS (or the router's DNS); direct `:53` gets poisoned and YouTube resolves to fake IPs | `pf` blocks all client `:53` and only allows clean resolvers that egress via WARP (1.1.1.1 / 8.8.8.8 etc.) |

---

## Architecture: the trio

This domain uses one control script (`warpgw-ctl.sh`) to toggle three parts together:

```
   +-------------+  point gateway at Mac  +----------------------- Mac ----------------------+
   |   client    | ---------------------> | (1) IPv4 forwarding  forwarding=1               |
   | (TV/phone/  |                        | (2) pf rules         warpshare.pf               |--> WARP(utun0) --> Internet
   |     PC)     | <--------------------- | (3) RA-kill          ra-kill.sh -> ra-kill.py    |
   +-------------+  IPv6 fake RA (drop default route) +----------------------------------------+
```

1. **IPv4 forwarding** -- `sysctl net.inet.ip.forwarding=1`, lets the Mac forward packets not addressed to itself.
2. **pf rules** (`warpshare.pf`) -- NAT to WARP + MSS clamping (avoids large packets being dropped) + DNS anti-poisoning.
3. **RA-kill daemon** (`ra-kill.py`, launched via `ra-kill.sh`) -- Python/scapy, L2-unicasts a `RouterLifetime=0` + `RDNSS lifetime=0` RA to each gateway client's device MAC to suppress IPv6 default routes.

### Key design: auto-discovered, per-device L2-unicast

The whole logic **adapts automatically to changes of network, device, and
router** without editing any file:

- **pf uses dynamic interface syntax**: source addresses use `(en0:network)`
  (en0's current subnet), and the local pass uses `(en0)` (this host's current
  address). pf resolves them at runtime, so it follows a Wi-Fi change automatically.
- **RA-kill auto-discovers gateway clients** (no hardcoded MAC/device list):
  - Gateway clients -> read from `pfctl -s states` (any local IP with an
    external connection is a gateway user). Combined with ARP to resolve MAC.
  - Real router LL -> read at runtime from `netstat -rn -f inet6`, supplemented
    by a live RA sniffer thread that mirrors the real router's RDNSS. Re-read
    every cycle, so it follows a network change.
  - **L2-unicast delivery**: each RA is sent with `Ether(dst=<device MAC>)`.
    On Wi-Fi, multicast (33:33:00:00:00:01) is sent at the lowest rate with
    no ACK/retry, so sleepy devices (Android TV) miss it. L2-unicast is ACKed,
    retransmitted, and delivered at normal rate -- this is the key to making
    the Android TV reliably drop its v6 route.
  - Sticky TTL: once a device MAC is seen, it keeps being targeted for 10
    minutes even if its pf states briefly disappear, to avoid IPv6 flapping.

---

## Directory layout

```
~/.xcli/warpgw/
├── config.yaml          domain metadata (auto-discovered by xcli)
├── warpgw-ctl.sh        control script (the real body of every command)
├── warpshare.pf         pf rules (NAT + MSS + DNS anti-poisoning)
├── ra-kill.sh           launcher for ra-kill.py (locates python3+scapy, exec)
├── ra-kill.py           RA-kill daemon (Python/scapy, L2-unicast per device)
├── rakill.log           RA-kill runtime log
└── <subcommand>/config.yaml  up down restart status install uninstall logs
```

---

## Commands

| Command | Purpose | Privilege |
|---------|---------|-----------|
| `xcli warpgw up` | Start the gateway (forwarding + pf + RA-kill), temporary mode | sudo |
| `xcli warpgw down` | Stop and restore to system default | sudo |
| `xcli warpgw restart` | Reload (use after changing rules / script) | sudo |
| `xcli warpgw install` | Install as auto-start on boot (launchd); also auto-installs `scapy` if missing | sudo |
| `xcli warpgw uninstall` | Uninstall auto-start and stop | sudo |
| `xcli warpgw status` | Show forwarding / pf / python / RA-kill / auto-start / WARP status | sudo recommended |
| `xcli warpgw logs` | Show RA-kill logs | — |

> `up` is temporary (lost on reboot); use `install` for a lasting setup.

---

## How a client connects

On the device you want proxied, change the network to **static / manual** and set:

- **Gateway / Router** -> this Mac's en0 address
  (find it with: `ipconfig getifaddr en0`)
- **DNS** -> `1.1.1.1` or `8.8.8.8`
  (`:53` to other DNS is blocked by pf; these two egress via WARP, clean and unpoisoned)

Once set, the device's traffic is taken over automatically, and within ~3s
RA-kill also suppresses its IPv6 leak. **No per-device configuration is needed
on the Mac.**

> To revert a device: switch its network back to "Automatic (DHCP)".

---

## Troubleshooting

```bash
# 1) Overall status (forwarding/pf/RA-kill/auto-start/WARP all OK?)
sudo xcli warpgw status

# 2) Check whether RA-kill is sending suppression RAs
xcli warpgw logs
#   Typical output: round N: router_ll=fe80::1 rdnss=[...] active=1 targeted=2
```

Common issues:

- **A device is still stuck / cannot open** -> confirm its gateway really points at the Mac; in `status`, pf, forwarding and WARP are all "on/online".
- **YouTube resolves to a weird IP (poisoned)** -> confirm the device's DNS is set to 1.1.1.1 / 8.8.8.8, and that the RA-kill daemon is shown running in `status`.
- **`scapy` not installed** -> run `sudo xcli warpgw install` (auto-installs), or `python3 -m pip install scapy` manually.
- **The WARP interface is not called utun0** -> see "Assumptions & limitations" below.

---

## Assumptions & limitations

- **Interface names are hardcoded to `en0` (LAN) and `utun0` (WARP)**. On the same
  Mac over Wi-Fi it is usually en0; if you switch to a USB NIC / wired port
  (becomes something like `en5`), or the WARP tunnel is not `utun0`, edit
  `LAN_IF` / `WARP_IF` at the top of `warpgw-ctl.sh` and the interface names in
  `warpshare.pf`.
- **Relies on the Cloudflare WARP client** being connected with a `utun0` default
  route in the routing table (which Chinese IPs go direct is decided by WARP's
  own split table, see `xcli warp`).
- **Requires root**: forwarding, pf, and sending raw packets (scapy) all need root,
  so up/down/restart/install/uninstall go through sudo.
- **Python 3 + scapy**: required by RA-kill. `install` auto-installs scapy via pip
  if missing. No special system dependencies beyond a working python3.

---

## Reversibility

- `xcli warpgw down` will: stop RA-kill -> `pfctl -f /etc/pf.conf` restore system pf -> disable IPv4 forwarding.
- `xcli warpgw uninstall` additionally removes the launchd auto-start config, so it no longer auto-restores after reboot.
- Client side: switch back to DHCP; after RA-kill stops, the router's next normal RA restores its IPv6 default route.
