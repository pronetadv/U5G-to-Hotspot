# U5G Setup Plan — Windows Host + UniFi 5G Backup (WiFi & Cellular WAN)

**Status:** Cellular WAN Working  
**Date:** Thu Jun 19 2026  
**Device:** UniFi 5G Backup (U5G-US)  
- **Firmware:** U5G-Antenna.1.3.4  
- **Kernel:** Linux 5.15.167-debug armv7l  
**Host OS:** Windows 11 (WSL2 Mirrored Mode)  
**SSH:** `sshpass -p 'pronet21' ssh pronetadv@192.168.1.20`

---

## Network Topology

```
Windows/WSL (192.168.1.1/24) ←──USB──→ U5G br0 (192.168.1.20/24)
                                              │
                                        ┌─────┴─────┐
                                        │           │
                                   rmnet_data0    gre1
                                   192.0.0.2/27   100.127.125.128/31
                                        │        peer 192.168.1.1
                                     Cellular
```

### Interface Summary
| Interface | Host | Address | Role |
|-----------|------|---------|------|
| WiFi (eth*) | Windows/WSL | 192.168.26.117/24 (gw .99) | WiFi WAN uplink |
| Ethernet (eth*) | Windows/WSL | 192.168.1.1/24 (gw .20) | Port to U5G (USB dongle or built-in) |
| vEthernet (WSL) | Windows | 172.27.64.1/20 | WSL Hyper-V switch |
| u5g-gre (WSL) | WSL | 100.127.125.129/31 | GRE tunnel (outbound OK, Windows blocks return) |
| U5G LAN (br0) | U5G | 192.168.1.20/24 | Management IP, DHCP server |
| U5G GRE (gre1) | U5G | 100.127.125.128/31 | GRE endpoint, peer 192.168.1.1 |
| U5G Cellular (rmnet_data0) | U5G | 192.0.0.2/27 | 5G cellular WAN |

---

## 1. WINDOWS HOST — NETWORK SETUP

### Step 1.1: WSL Mirrored Mode
```powershell
# %USERPROFILE%\.wslconfig
[wsl2]
networkingMode=mirrored
```

### Step 1.2: Laptop Ethernet IP
The laptop's Ethernet port (USB dongle or built-in) connected to the U5G must be on `192.168.1.0/24`.
The script auto-detects which WSL interface connects to the U5G and verifies the subnet.
```powershell
# Replace "Ethernet 3" with your actual interface name (check Get-NetAdapter)
New-NetIPAddress -InterfaceAlias "Ethernet 3" -IPAddress 192.168.1.1 -PrefixLength 24
New-NetRoute -InterfaceAlias "Ethernet 3" -DestinationPrefix "0.0.0.0/0" -NextHop 192.168.1.20
```

---

## 2. U5G CONFIGURATION — TWO WAN MODES

The U5G supports two WAN modes. Only one default route is active at a time.

### Mode A: WiFi WAN (Default — traffic via Windows → WiFi)
```bash
# NAT already handled by Windows. Just set default route to Windows.
ip route del default via 192.168.1.1 dev br0 2>/dev/null
ip route add default via 192.168.1.1 dev br0
```

### Mode B: Cellular WAN (traffic via U5G 5G modem)
Apply all of the following **together**:

```bash
# 1. Valves (rp_filter + ip_forward)
for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $i; done
echo 1 > /proc/sys/net/ipv4/ip_forward

# 2. NAT for LAN through cellular
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o rmnet_data0 -j MASQUERADE

# 3. Allow forwarding from/to LAN
iptables -I FORWARD 1 -i br0 -j ACCEPT
iptables -I FORWARD 1 -o br0 -j ACCEPT

# 4. Switch default route to cellular
ip route del default via 192.168.1.1 dev br0 2>/dev/null
ip route add default via 192.0.0.2 dev rmnet_data0

# 5. CRITICAL: Add LAN route to table 3 so cellular return traffic
#    doesn't loop back through rmnet_data0 (PBR rule iif rmnet_data0 → table 3)
ip route add 192.168.1.0/24 dev br0 table 3
```

If table 3 route is missing, return packets arrive on `rmnet_data0`, hit PBR rule `iif rmnet_data0 lookup 3`, find no route to 192.168.1.0/24, and default back through `rmnet_data0` — causing a routing loop.

### Verify Current Mode
```bash
ip route show | grep default
# WiFi WAN:    default via 192.168.1.1 dev br0
# Cellular:    default via 192.0.0.2 dev rmnet_data0
```

---

## 3. WSL — ROUTE TEST TRAFFIC THROUGH U5G

The script (`setup_u5g_cellular_wan.sh`) adds a test route to `1.1.1.1` automatically, detecting the correct WSL interface. Manual equivalent:
```bash
# Find which interface connects to the U5G
ip route get 192.168.1.20
# → 192.168.1.20 via 192.168.1.20 dev ethX src 192.168.1.1

# Add route through that interface
sudo ip route add 1.1.1.1 via 192.168.1.20 dev ethX
ping -c 4 1.1.1.1
# Expected: 38-220ms (cellular latency varies)
traceroute -n 1.1.1.1
# Hop 1: 192.168.1.20 (U5G), then cellular carrier
```

---

## 4. TESTING

### Cellular WAN
```bash
# From WSL (add route first)
sudo ip route add 1.1.1.1 via 192.168.1.20 dev eth1
ping -c 4 1.1.1.1

# From U5G directly
sshpass -p 'pronet21' ssh pronetadv@192.168.1.20 'ping -c 4 -I rmnet_data0 1.1.1.1'
```

### WiFi WAN
- Connect client devices to U5G LAN (WiFi or wired)
- Client gets DHCP from U5G, gateway = 192.168.1.20
- Client reaches internet via U5G → Windows USB Ethernet → WiFi

---

## 5. TROUBLESHOOTING

| Symptom | Likely Cause | Fix |
|---------|-------------|------|
| Can't SSH to U5G | Wrong laptop IP | Set Windows USB Ethernet to 192.168.1.1/24 |
| Cellular WAN: ping from WSL reaches U5G but no internet | Missing table 3 LAN route | `ip route add 192.168.1.0/24 dev br0 table 3` |
| Cellular WAN: NAT counters show 0 | FORWARD chain blocked | `iptables -I FORWARD -i br0 -j ACCEPT` |
| WiFi WAN broken after cellular mode | Default route still on cellular | Switch to WiFi WAN mode (revert cellular) |
| U5G unreachable after reboot | All config lost (volatile) | Re-apply full config from Section 6 |
| GRE ping from WSL fails | Windows blocks Protocol 47 | Use Cellular WAN Mode B instead of GRE |

---

## 6. QUICK SCRIPTS

### After U5G Reboot — Valves
```bash
sshpass -p 'pronet21' ssh pronetadv@192.168.1.20 '
for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $i; done
echo 1 > /proc/sys/net/ipv4/ip_forward
'
```

### Enable Cellular WAN
```bash
sshpass -p 'pronet21' ssh pronetadv@192.168.1.20 '
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o rmnet_data0 -j MASQUERADE
iptables -I FORWARD 1 -i br0 -j ACCEPT
iptables -I FORWARD 1 -o br0 -j ACCEPT
ip route del default via 192.168.1.1 dev br0 2>/dev/null
ip route add default via 192.0.0.2 dev rmnet_data0
ip route add 192.168.1.0/24 dev br0 table 3
'
```

### Enable WiFi WAN
```bash
sshpass -p 'pronet21' ssh pronetadv@192.168.1.20 '
ip route del default via 192.0.0.2 dev rmnet_data0 2>/dev/null
ip route add default via 192.168.1.1 dev br0
'
```

**Important:** U5G firmware does NOT persist any of these changes across reboots.

---

## 7. GRE TUNNEL NOTE

GRE tunnel (gre1 on U5G, u5g-gre on WSL) works for outbound traffic. Return traffic is blocked because Windows does not pass Protocol 47 (GRE) raw packets to WSL in mirrored mode — Windows sends ICMP "protocol unreachable" instead.

The Cellular WAN mode (Section 2, Mode B) achieves the same result without requiring GRE.

---

## Scripts
- **`setup_u5g_cellular_wan.sh`** — One-shot config from stock to Cellular WAN (run with `sudo bash`)
- **`setup_u5g_ssh_proxy.sh`** — Legacy GRE tunnel approach (Windows blocks GRE return)
- **`setup_U5G.bat`** — Windows batch: SSH SOCKS proxy + isolated Chrome session

## Checklist
- [x] Windows/WSL IP = 192.168.1.1/24, reachable
- [x] U5G SSH accessible at 192.168.1.20
- [x] GRE tunnel created (outbound working)
- [x] Cellular route in table 3: 192.168.1.0/24 dev br0 (critical fix)
- [x] Cellular WAN working from WSL (38-87ms)
- [x] WiFi WAN working (default mode)
- [ ] Test client device via WiFi WAN
- [ ] Test switching between modes

**Last Updated:** Thu Jun 19 2026
