#!/bin/bash
#
# Destroy all K8s Simple Homelab UTM VMs
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# VM names
VMS=(vault jump etcd-1 master-1 worker-1 worker-2)

header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
}

if ! command -v utmctl &> /dev/null; then
    echo -e "${RED}Error: utmctl not found${NC}"
    exit 1
fi

header "K8s Simple Homelab VM Destroyer"

echo ""
utmctl list
echo ""

echo -e "${YELLOW}WARNING: This will permanently delete the following VMs:${NC}"
for vm in "${VMS[@]}"; do
    echo "  - $vm"
done
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

header "Stopping VMs"
for vm in "${VMS[@]}"; do
    echo -n "  Stopping $vm... "
    utmctl stop "$vm" 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}skipped${NC}"
done

sleep 2

header "Deleting VMs"
for vm in "${VMS[@]}"; do
    echo -n "  Deleting $vm... "
    utmctl delete "$vm" 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}not found${NC}"
done

# Clean /etc/hosts
HOSTS_MARKER="# K8s Simple Homelab VMs"
if grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}Removing /etc/hosts entries (requires sudo)...${NC}"
    sudo sed -i '' "/${HOSTS_MARKER}/,/# End K8s Simple Homelab/d" /etc/hosts
    echo -e "${GREEN}Removed /etc/hosts entries${NC}"
fi

# Clean SSH config
SSH_CONFIG="$HOME/.ssh/config"
SSH_MARKER="# K8s Simple Homelab"
if grep -q "$SSH_MARKER" "$SSH_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}Removing SSH config entries...${NC}"
    sed -i '' "/${SSH_MARKER}/,/# End K8s Simple Homelab/d" "$SSH_CONFIG"
    sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$SSH_CONFIG"
    echo -e "${GREEN}Removed SSH config entries${NC}"
fi

# Clean known_hosts (stale host keys cause warnings on recreate)
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if [[ -f "$KNOWN_HOSTS" ]]; then
    echo -e "${YELLOW}Removing known_hosts entries for VMs...${NC}"
    for vm in "${VMS[@]}"; do
        ssh-keygen -R "$vm" -f "$KNOWN_HOSTS" 2>/dev/null || true
    done
    echo -e "${GREEN}Removed known_hosts entries${NC}"
fi

header "Cleanup Complete"
echo ""
echo "Remaining VMs:"
utmctl list
echo ""
