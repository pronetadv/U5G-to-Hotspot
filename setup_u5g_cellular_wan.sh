#!/bin/bash
# setup_u5g_cellular_wan.sh
# Configures the U5G as a cellular WAN gateway for a WSL2 (Windows) host.
#
# Usage:  sudo bash setup_u5g_cellular_wan.sh
#
# Prerequisites:
#   - WSL2 with mirrored networking mode
#   - sshpass installed (sudo apt install sshpass)
#   - U5G connected via Ethernet (USB dongle or built-in) at 192.168.1.20
#   - Laptop Ethernet port set to an IP on 192.168.1.0/24 (e.g. 192.168.1.1/24)
#
# The script auto-detects:
#   - Which WSL interface connects to the U5G (eth0, eth1, etc.)
#   - That the interface is on the 192.168.1.0/24 subnet
#   - The gateway (192.168.1.20) is reachable
#
# What this does:
#   1. U5G valves: rp_filter=0, ip_forward=1
#   2. U5G NAT for LAN through cellular (rmnet_data0)
#   3. U5G FORWARD rules for br0
#   4. U5G default route switched to cellular
#   5. U5G table 3 route added (critical: prevents return traffic loop)
#   6. WSL test routes added
#   7. Connectivity verified
#
# To revert to WiFi WAN mode:
#   Run with:  bash setup_u5g_cellular_wan.sh --wifi

set -euo pipefail

# --- Configuration ---
U5G_IP="192.168.1.20"
CELLULAR_IFACE="rmnet_data0"
CELLULAR_GW="192.0.0.2"
LAN_SUBNET="192.168.1.0/24"
REQUIRED_GW="192.168.1.20"
TEST_IP="1.1.1.1"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

# --- Cleanup on exit ---
cleanup() {
    local ec=$?
    set +e
    if [ $ec -ne 0 ] && [ $ec -ne 99 ]; then
        echo
        echo -e "${YELLOW}Script exited with error (code $ec).${NC}"
        echo "The U5G may be in a partial state. Run the wifi mode switch to restore:"
        echo "  bash setup_u5g_cellular_wan.sh --wifi"
    fi
    exit $ec
}
trap cleanup EXIT

# --- Help / Mode Select ---
if [ $# -ge 1 ]; then
    case "$1" in
        --wifi|-w)
            MODE="wifi"
            ;;
        --cellular|-c)
            MODE="cellular"
            ;;
        --help|-h)
            echo "Usage: sudo bash $0 [--wifi|--cellular]"
            echo "  --wifi      Switch U5G to WiFi WAN mode"
            echo "  --cellular  Switch U5G to Cellular WAN mode (default)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
else
    MODE="cellular"
fi

# --- Root Check ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root (sudo).${NC}"
    exit 1
fi

echo "======================================================"
echo "  U5G Cellular/WiFi WAN Gateway Setup"
echo "======================================================"
echo

# --- Prompt for U5G Credentials ---
read -p "U5G SSH username [avfxu5g]: " U5G_USER
U5G_USER="${U5G_USER:-avfxu5g}"
read -s -p "U5G SSH password: " U5G_PASS
echo
if [ -z "${U5G_PASS}" ]; then
    fail "Password cannot be empty."
    exit 1
fi

SSHPASS_CMD="sshpass -p ${U5G_PASS}"
SSH_CMD="${SSHPASS_CMD} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${U5G_USER}@${U5G_IP}"

echo

# --- Prerequisite Checks ---
info "Checking prerequisites..."

if ! command -v sshpass &>/dev/null; then
    fail "sshpass not found. Install: sudo apt install sshpass"
    exit 1
fi
ok "sshpass available"

# --- Find interface connected to U5G ---
U5G_ROUTE=$(ip route get "${U5G_IP}" 2>/dev/null || echo "")
WSL_USB_IFACE=$(echo "${U5G_ROUTE}" | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)
WSL_USB_IP=$(echo "${U5G_ROUTE}" | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -1)

if [ -z "${WSL_USB_IFACE}" ] || [ -z "${WSL_USB_IP}" ]; then
    fail "No route to U5G (${U5G_IP}). Verify the U5G is connected and reachable."
    exit 1
fi
ok "U5G reachable via interface ${WSL_USB_IFACE} (${WSL_USB_IP})"

# --- Verify interface is on the correct subnet ---
WSL_PREFIX=$(ip -4 addr show "${WSL_USB_IFACE}" 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f2)
if [ -z "${WSL_PREFIX}" ]; then
    fail "Could not determine subnet prefix for ${WSL_USB_IFACE}."
    exit 1
fi

# --- Check that WSL interface IP is in 192.168.1.0/24 ---
WSL_OCTET=$(echo "${WSL_USB_IP}" | cut -d. -f1-3)
if [ "${WSL_OCTET}" != "192.168.1" ]; then
    fail "Interface ${WSL_USB_IFACE} (${WSL_USB_IP}) is not on the 192.168.1.0/24 subnet."
    echo "  The U5G expects the connected port to be on 192.168.1.0/24."
    echo "  Current route to ${U5G_IP}: ${U5G_ROUTE}"
    exit 1
fi
ok "${WSL_USB_IFACE} is on subnet 192.168.1.0/24"

# --- Check gateway route to U5G ---
GW_CHECK=$(ip route show "${REQUIRED_GW}" 2>/dev/null || echo "")
if [ -z "${GW_CHECK}" ]; then
    info "No explicit route to ${REQUIRED_GW} — using subnet directly."
fi

if ! sshpass -p "${U5G_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${U5G_USER}@${U5G_IP}" "exit" &>/dev/null; then
    fail "SSH to U5G failed. Check credentials."
    exit 1
fi
ok "SSH to U5G authenticated"

# --- Check cellular interface on U5G ---
CELL_STATUS=$(sshpass -p "${U5G_PASS}" ssh -o StrictHostKeyChecking=no "${U5G_USER}@${U5G_IP}" \
    "ip -br addr show ${CELLULAR_IFACE} 2>/dev/null | awk '{print \$3}'" 2>/dev/null)
if [ -z "${CELL_STATUS}" ]; then
    fail "Cellular interface ${CELLULAR_IFACE} not found on U5G."
    echo "  Check if the U5G has cellular connectivity."
    exit 1
fi
ok "U5G cellular (${CELLULAR_IFACE}): ${CELL_STATUS}"

echo

# =====================================================================
# WiFi WAN Mode
# =====================================================================
if [ "${MODE}" = "wifi" ]; then
    echo -e "${YELLOW}Switching U5G to WiFi WAN mode...${NC}"
    echo

    # Revert cellular default route, restore WiFi WAN
    ${SSH_CMD} '
        ip route del default via '"${CELLULAR_GW}"' dev '"${CELLULAR_IFACE}"' 2>/dev/null
        ip route add default via 192.168.1.1 dev br0
    ' || true

    echo
    echo -e "${GREEN}WiFi WAN mode active.${NC}"
    echo "  Default route: via 192.168.1.1 dev br0"
    echo
    echo "Note: The NAT, FORWARD, and table 3 rules remain on the U5G"
    echo "but are inert when the default route points to WiFi."
    echo "To fully clean up, SSH into the U5G and run:"
    echo "  iptables -t nat -D POSTROUTING -s ${LAN_SUBNET} -o ${CELLULAR_IFACE} -j MASQUERADE 2>/dev/null"
    echo "  iptables -D FORWARD -i br0 -j ACCEPT 2>/dev/null && iptables -D FORWARD -o br0 -j ACCEPT 2>/dev/null"
    echo "  ip route del ${LAN_SUBNET} dev br0 table 3 2>/dev/null"
    echo
    sudo ip route del "${TEST_IP}" via "${U5G_IP}" dev "${WSL_USB_IFACE}" 2>/dev/null || true
    exit 0
fi

# =====================================================================
# Cellular WAN Mode
# =====================================================================
echo -e "${YELLOW}Configuring U5G for Cellular WAN mode...${NC}"
echo

# --- Step 1: U5G Valves ---
info "Step 1: Opening U5G valves (rp_filter, ip_forward)..."
${SSH_CMD} '
    for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$i"; done
    echo 1 > /proc/sys/net/ipv4/ip_forward
' || { fail "Failed to set U5G valves"; exit 1; }
ok "rp_filter=0, ip_forward=1"

# --- Step 2: U5G NAT ---
info "Step 2: Adding NAT for LAN through cellular..."
${SSH_CMD} '
    iptables -t nat -C POSTROUTING -s '"${LAN_SUBNET}"' -o '"${CELLULAR_IFACE}"' -j MASQUERADE 2>/dev/null ||
    iptables -t nat -A POSTROUTING -s '"${LAN_SUBNET}"' -o '"${CELLULAR_IFACE}"' -j MASQUERADE
' || { fail "Failed to add NAT rule"; exit 1; }
ok "NAT masquerade: ${LAN_SUBNET} → ${CELLULAR_IFACE}"

# --- Step 3: U5G FORWARD ---
info "Step 3: Adding FORWARD rules for br0..."
${SSH_CMD} '
    iptables -C FORWARD -i br0 -j ACCEPT 2>/dev/null ||
    iptables -I FORWARD 1 -i br0 -j ACCEPT
    iptables -C FORWARD -o br0 -j ACCEPT 2>/dev/null ||
    iptables -I FORWARD 1 -o br0 -j ACCEPT
' || { fail "Failed to add FORWARD rules"; exit 1; }
ok "FORWARD rules for br0 added"

# --- Step 4: U5G Default Route → Cellular ---
info "Step 4: Switching default route to cellular..."
${SSH_CMD} '
    ip route del default via 192.168.1.1 dev br0 2>/dev/null
    ip route add default via '"${CELLULAR_GW}"' dev '"${CELLULAR_IFACE}"'
' || { fail "Failed to set cellular default route"; exit 1; }
ok "Default route: via ${CELLULAR_GW} dev ${CELLULAR_IFACE}"

# --- Step 5: Table 3 Route (Critical Fix) ---
info "Step 5: Adding LAN route to table 3 (prevents return traffic loop)..."
${SSH_CMD} '
    ip route add '"${LAN_SUBNET}"' dev br0 table 3 2>/dev/null ||
    echo "  (route already exists)"
' || true
ok "Route ${LAN_SUBNET} → dev br0 in table 3"

echo

# --- Step 6: WSL Test Route ---
info "Step 6: Adding WSL test route..."
sudo ip route add "${TEST_IP}" via "${U5G_IP}" dev "${WSL_USB_IFACE}" 2>/dev/null || \
sudo ip route replace "${TEST_IP}" via "${U5G_IP}" dev "${WSL_USB_IFACE}"
ok "WSL route: ${TEST_IP} → via ${U5G_IP} dev ${WSL_USB_IFACE}"

echo
echo "======================================================"
echo "  Verification"
echo "======================================================"
echo

# --- Verify U5G default route ---
U5G_DEFAULT=$(${SSH_CMD} "ip route show | grep default" 2>/dev/null || echo "UNKNOWN")
if echo "${U5G_DEFAULT}" | grep -q "${CELLULAR_GW}"; then
    ok "U5G default route: ${U5G_DEFAULT}"
else
    fail "U5G default route unexpected: ${U5G_DEFAULT}"
fi

# --- Verify table 3 ---
TABLE3_LAN=$(${SSH_CMD} "ip route show table 3 | grep ${LAN_SUBNET}" 2>/dev/null || echo "MISSING")
if echo "${TABLE3_LAN}" | grep -q "dev br0"; then
    ok "Table 3 route: ${TABLE3_LAN}"
else
    fail "Table 3 route missing (critical!). Add:"
    echo "  ssh ${U5G_USER}@${U5G_IP} 'ip route add ${LAN_SUBNET} dev br0 table 3'"
fi

# --- Verify NAT ---
NAT_OK=$(${SSH_CMD} "iptables -t nat -L POSTROUTING -v -n 2>/dev/null | grep ${LAN_SUBNET}" || echo "MISSING")
if echo "${NAT_OK}" | grep -q "MASQUERADE"; then
    ok "NAT rule present"
else
    fail "NAT rule missing"
fi

# --- Test connectivity ---
echo
info "Testing internet via U5G cellular (${TEST_IP})..."
if ping -c 4 "${TEST_IP}" 2>&1; then
    echo
    ok "Internet via U5G cellular: WORKING"
else
    echo
    fail "No reply from ${TEST_IP}. Troubleshooting:"
    echo "  1. Check U5G cellular: ${SSHPASS_CMD} ssh ${U5G_USER}@${U5G_IP} 'ping -c 2 -I ${CELLULAR_IFACE} ${TEST_IP}'"
    echo "  2. Verify NAT counters: ssh ${U5G_USER}@${U5G_IP} 'iptables -t nat -L POSTROUTING -v -n'"
    echo "  3. Check FORWARD counters: ssh ${U5G_USER}@${U5G_IP} 'iptables -L FORWARD -v -n'"
    echo "  4. Ensure table 3 has LAN route: ssh ${U5G_USER}@${U5G_IP} 'ip route show table 3'"
fi

echo
echo "======================================================"
echo "  Summary"
echo "======================================================"
echo
echo "  U5G Mode:    Cellular WAN (via ${CELLULAR_IFACE})"
echo "  U5G Gateway: ${U5G_IP}"
echo "  Laptop IP:   ${WSL_USB_IP}"
echo "  Test route:  ${TEST_IP} → ${U5G_IP}"
echo
echo "  To switch to WiFi WAN mode:"
echo "    sudo bash $0 --wifi"
echo
echo "  To test other IPs through cellular (from WSL):"
echo "    sudo ip route add <IP> via ${U5G_IP} dev ${WSL_USB_IFACE}"
echo
if ping -c 1 "${TEST_IP}" &>/dev/null; then
    echo -e "  ${GREEN}Cellular internet: CONNECTED${NC}"
else
    echo -e "  ${YELLOW}Cellular internet: check troubleshooting above${NC}"
fi
echo
