#!/bin/bash
#
# K8s Simple Homelab - Start All VMs
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

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Starting K8s Simple Homelab VMs${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo ""

# Ensure UTM is running
echo -n "Checking UTM... "
if ! pgrep -x UTM >/dev/null 2>&1; then
    echo -e "${YELLOW}not running, starting UTM${NC}"
    open -a UTM
    sleep 5
elif ! utmctl list >/dev/null 2>&1; then
    echo -e "${YELLOW}unresponsive, restarting UTM${NC}"
    pkill -x UTM 2>/dev/null || true
    sleep 2
    open -a UTM
    sleep 5
else
    echo -e "${GREEN}OK${NC}"
fi
echo ""

count=0
skipped=0

for name in "${VMS[@]}"; do
    echo -n "  Starting $name... "
    if utmctl start "$name" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        ((count++))
    else
        echo -e "${YELLOW}already running${NC}"
        ((skipped++))
    fi
done

echo ""
echo -e "${GREEN}✓${NC} Started $count VMs (skipped $skipped)"
echo ""
