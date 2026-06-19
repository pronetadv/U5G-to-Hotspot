# U5G to Laptop Hotspot Service

Turn a **UniFi 5G Backup (U5G-US)** into a portable cellular WAN hotspot for a Windows laptop via USB/Ethernet.

## Quick Start

```
sudo bash setup_u5g_cellular_wan.sh       # switch to cellular WAN
sudo bash setup_u5g_cellular_wan.sh --wifi # revert to WiFi WAN
```

## Prerequisites

- Windows 11 + WSL2 with [mirrored networking](https://learn.microsoft.com/en-us/windows/wsl/networking)
- `sshpass` installed in WSL (`sudo apt install sshpass`)
- Laptop Ethernet port set to `192.168.1.1/24` (the port connected to the U5G)
- U5G at `192.168.1.20` (script prompts for SSH credentials; default user: `avfxu5g`)

## How It Works

```
Windows/WSL (192.168.1.1/24) ←──USB/Ethernet──→ U5G br0 (192.168.1.20/24)
                                                   │
                                              rmnet_data0
                                              192.0.0.2/27
                                                   │
                                                Cellular
```

The script configures the U5G with NAT, IP forwarding, and a policy route (table 3) to prevent routing loops — making the cellular connection available to the laptop.

## Files

| File | Purpose |
|------|---------|
| `setup_u5g_cellular_wan.sh` | One-shot cellular WAN setup (NAT, routes, table 3 fix) |
| `setup_u5g_ssh_proxy.sh` | Legacy GRE tunnel approach (Windows blocks GRE return traffic) |
| `plans/plans.md` | Full documentation, topology, troubleshooting |

## Switching Modes

- **Cellular WAN** — traffic routes through the U5G's 5G modem (NAT'd)
