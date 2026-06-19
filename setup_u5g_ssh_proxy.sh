#!/bin/bash
# 1. CLEANUP
echo "[*] Cleaning up existing tunnel..."
sudo ip link delete u5g-gre 2>/dev/null

# 2. BUILD
echo "[*] Building GRE tunnel to 192.168.1.20..."
# Creates tunnel using the hardcoded peer IPs required by the device
sudo ip link add u5g-gre type gre remote 192.168.1.20 local 192.168.1.1 ttl 255
# Set MTU to 1476 and enable Multicast (essential for U5G handshakes)
sudo ip link set dev u5g-gre mtu 1476 multicast on
# Assign the laptop's tunnel IP in the /31 subnet
sudo ip addr add 100.127.125.129/31 dev u5g-gre
sudo ip link set u5g-gre up

# 3. TEST
echo "[*] Testing link to U5G Tunnel Interface..."
if ping -c 3 100.127.125.128 > /dev/null; then
    echo "[SUCCESS] GRE Tunnel Handshake Established."
    echo "[*] Adding test route for internet verification..."
    sudo ip route add 1.1.1.1 via 100.127.125.128 dev u5g-gre
    traceroute -n 1.1.1.1
else
    echo "[FAILURE] U5G not responding. Check Device-side valves and Windows Firewall Protocol 47."
fi
