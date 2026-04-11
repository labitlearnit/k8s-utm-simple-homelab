#!/bin/bash
#
# K8s Simple Homelab - Stop All VMs (Full Shutdown)
#

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# VM names
VMS=(vault jump etcd-1 master-1 worker-1 worker-2)

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Stopping K8s Simple Homelab VMs (Full Shutdown)${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Frees ~18GB RAM. VMs will need full boot to start.${NC}"
echo ""

count=0
skipped=0

for name in "${VMS[@]}"; do
    echo -n "  Stopping $name... "
    if utmctl stop "$name" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        ((count++))
    else
        echo -e "${YELLOW}skipped${NC}"
        ((skipped++))
    fi
done

echo ""
echo -e "${GREEN}✓${NC} Stopped $count VMs (skipped $skipped)"
echo ""
echo "Start with: ./scripts/start_vms.sh"
