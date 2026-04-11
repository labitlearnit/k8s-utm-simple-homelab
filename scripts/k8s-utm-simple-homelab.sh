#!/bin/bash
#
# K8s Simple Homelab - Automated VM Creation & Cluster Deployment
# Creates 6 VMs using QEMU backend and deploys a simple K8s cluster
#

set -e

# Track total script time
SCRIPT_START_TIME=$(date +%s)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directories
PROJECT_DIR="$HOME/k8s-utm-simple-homelab"
ISO_DIR="$PROJECT_DIR/iso"
IMG_DIR="$PROJECT_DIR/images"
BIN_DIR="$PROJECT_DIR/k8s-binaries"
UTM_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

# Binary versions (must match ansible role vars)
ETCD_VERSION="3.5.12"
K8S_VERSION="1.32.0"
CONTAINERD_VERSION="1.7.24"
RUNC_VERSION="1.2.4"
CALICO_VERSION="3.28.0"
K8S_DOWNLOAD_URL="https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/arm64"
ETCD_DOWNLOAD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz"
CONTAINERD_DOWNLOAD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz"
RUNC_DOWNLOAD_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.arm64"
CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

# Ubuntu Cloud Image
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
CLOUD_IMG_BASE="$IMG_DIR/ubuntu-24.04-cloudimg-arm64.img"

# VM Definitions: name:ip_suffix:ram_mb:vcpu:disk_gb
VMS=(
    "vault:11:2048:1:20"
    "jump:12:2048:1:20"
    "etcd-1:21:2048:1:20"
    "master-1:31:4096:2:30"
    "worker-1:41:4096:2:40"
    "worker-2:42:4096:2:40"
)

header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
}

generate_uuid() {
    uuidgen | tr '[:lower:]' '[:upper:]'
}

generate_mac() {
    printf '42:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# /etc/hosts entries for all VMs
HOSTS_ENTRIES="
# K8s Simple Homelab VMs
192.168.64.11  vault
192.168.64.12  jump
192.168.64.21  etcd-1
192.168.64.31  master-1
192.168.64.41  worker-1
192.168.64.42  worker-2
"

# Create cloud-init ISO for a VM
create_cloud_init_iso() {
    local name=$1
    local ip=$2
    local ssh_key=$3
    local iso_file="$ISO_DIR/${name}-cidata.iso"
    
    local temp_dir=$(mktemp -d)
    
    cat > "$temp_dir/meta-data" << EOF
instance-id: ${name}
local-hostname: ${name}
EOF

    cat > "$temp_dir/user-data" << EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: false

users:
  - default
  - name: k8s
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_key}

ssh_pwauth: false
EOF

    # Jump needs package_update for extra packages; others skip for fast boot
    if [[ "$name" == "jump" ]]; then
        cat >> "$temp_dir/user-data" << 'JUMPEOF'

package_update: true
package_upgrade: false
packages:
  - openssh-server
  - qemu-guest-agent
  - git
  - python3-pip
  - python3-venv
  - unzip
  - curl
  - jq
  - sshpass
JUMPEOF
    elif [[ "$name" == "vault" ]]; then
        cat >> "$temp_dir/user-data" << 'VAULTEOF'

package_update: true
package_upgrade: false
packages:
  - unzip
  - curl
  - jq
  - gnupg
VAULTEOF
    elif [[ "$name" == worker-* ]]; then
        cat >> "$temp_dir/user-data" << 'WORKEREOF'

package_update: true
package_upgrade: false
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - socat
  - conntrack
WORKEREOF
    else
        cat >> "$temp_dir/user-data" << 'EOF'

package_update: false
package_upgrade: false
EOF
    fi

    cat >> "$temp_dir/user-data" << EOF

write_files:
  # Speed up boot - only check NoCloud datasource (skip AWS/GCP/Azure probing)
  - path: /etc/cloud/cloud.cfg.d/99-datasource.cfg
    content: |
      datasource_list: [NoCloud, None]
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      127.0.1.1 ${name}
      
      # K8s Simple Homelab VMs
      192.168.64.11  vault
      192.168.64.12  jump
      192.168.64.21  etcd-1
      192.168.64.31  master-1
      192.168.64.41  worker-1
      192.168.64.42  worker-2
      
      # IPv6
      ::1 ip6-localhost ip6-loopback
      fe00::0 ip6-localnet
      ff00::0 ip6-mcastprefix
      ff02::1 ip6-allnodes
      ff02::2 ip6-allrouters
EOF

    cat >> "$temp_dir/user-data" << 'EOF'

runcmd:
  # Disable network-wait-online (not needed, causes 2min delay with static IP)
  - systemctl disable systemd-networkd-wait-online.service || true
  - systemctl mask systemd-networkd-wait-online.service || true
  # Disk resize (fast)
  - growpart /dev/vda 1 || true
  - resize2fs /dev/vda1 || true
EOF

    # Add jump-specific runcmd
    if [[ "$name" == "jump" ]]; then
        cat >> "$temp_dir/user-data" << 'JUMPCMD'
  # Enable qemu-guest-agent (jump has it installed)
  - systemctl enable qemu-guest-agent || true
  - systemctl start qemu-guest-agent || true
  # Ensure .ssh directory permissions for k8s user
  - mkdir -p /home/k8s/.ssh && chown k8s:k8s /home/k8s/.ssh && chmod 700 /home/k8s/.ssh
  # Set Vault address in profile
  - echo 'export VAULT_ADDR="http://vault:8200"' >> /etc/profile.d/vault.sh
  - chmod +x /etc/profile.d/vault.sh
  # Install Ansible
  - pip3 install --break-system-packages ansible
  # Install HashiCorp tools (vault CLI, terraform)
  - wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg arch=arm64] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
  - apt-get update
  - apt-get install -y vault terraform
JUMPCMD
    fi

    cat > "$temp_dir/network-config" << EOF
version: 2
ethernets:
  enp0s1:
    dhcp4: false
    addresses:
      - ${ip}/24
    routes:
      - to: default
        via: 192.168.64.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF

    mkisofs -output "$iso_file" -volid cidata -joliet -rock "$temp_dir" 2>/dev/null
    rm -rf "$temp_dir"
    echo "$iso_file"
}

# Create UTM VM
create_vm() {
    local name=$1
    local ip=$2
    local ram_mb=$3
    local vcpu=$4
    local disk_gb=$5
    local ssh_key=$6
    
    local vm_dir="$UTM_DIR/${name}.utm"
    local data_dir="$vm_dir/Data"
    
    # Skip if VM exists
    if [[ -d "$vm_dir" ]]; then
        echo -e "${YELLOW}  Skipping $name (already exists)${NC}"
        return 0
    fi
    
    echo -n "  Creating $name ($ip, ${ram_mb}MB, ${vcpu}vCPU, ${disk_gb}GB)... "
    
    # Create directories
    mkdir -p "$data_dir"
    
    # Create disk from cloud image
    local disk_file="$data_dir/${name}-disk.qcow2"
    cp "$CLOUD_IMG_BASE" "$disk_file"
    qemu-img resize "$disk_file" "${disk_gb}G" 2>/dev/null
    
    # Create cloud-init ISO
    local cidata_iso=$(create_cloud_init_iso "$name" "$ip" "$ssh_key")
    
    # Convert cloud-init ISO to qcow2 (UTM expects this)
    local cidata_qcow2="$data_dir/${name}-cidata.qcow2"
    qemu-img convert -f raw -O qcow2 "$cidata_iso" "$cidata_qcow2" 2>/dev/null
    
    # Generate UUIDs
    local vm_uuid=$(generate_uuid)
    local disk_uuid=$(generate_uuid)
    local cidata_uuid=$(generate_uuid)
    local mac_addr=$(generate_mac)
    
    # Create config.plist
    cat > "$vm_dir/config.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Display</key>
	<array>
		<dict>
			<key>DownscalingFilter</key>
			<string>Linear</string>
			<key>DynamicResolution</key>
			<true/>
			<key>Hardware</key>
			<string>virtio-gpu-pci</string>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>${disk_uuid}</string>
			<key>ImageName</key>
			<string>${name}-disk.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
		<dict>
			<key>Identifier</key>
			<string>${cidata_uuid}</string>
			<key>ImageName</key>
			<string>${name}-cidata.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Information</key>
	<dict>
		<key>Icon</key>
		<string>linux</string>
		<key>IconCustom</key>
		<false/>
		<key>Name</key>
		<string>${name}</string>
		<key>UUID</key>
		<string>${vm_uuid}</string>
	</dict>
	<key>Input</key>
	<dict>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
	</dict>
	<key>Network</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>MacAddress</key>
			<string>${mac_addr}</string>
			<key>Mode</key>
			<string>Shared</string>
			<key>PortForward</key>
			<array/>
			<key>VlanGuestAddress</key>
			<string>192.168.64.0/24</string>
		</dict>
	</array>
	<key>QEMU</key>
	<dict>
		<key>AdditionalArguments</key>
		<array/>
		<key>BalloonDevice</key>
		<false/>
		<key>DebugLog</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>PS2Controller</key>
		<false/>
		<key>RNGDevice</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>TSO</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
	</dict>
	<key>Serial</key>
	<array/>
	<key>Sharing</key>
	<dict>
		<key>ClipboardSharing</key>
		<true/>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
	</dict>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUCount</key>
		<integer>${vcpu}</integer>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>ForceMulticore</key>
		<false/>
		<key>JITCacheSize</key>
		<integer>0</integer>
		<key>MemorySize</key>
		<integer>${ram_mb}</integer>
		<key>Target</key>
		<string>virt</string>
	</dict>
</dict>
</plist>
EOF

    echo -e "${GREEN}OK${NC}"
}

# Main
header "K8s Simple Homelab Setup"

echo ""
echo "This will create ${#VMS[@]} VMs in UTM:"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    echo "  - $name (192.168.64.${ip_suffix})"
done
echo ""

# Pre-authenticate sudo so it doesn't prompt mid-deployment (Step 5 needs it)
HOSTS_MARKER="# K8s Simple Homelab VMs"
if ! grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}sudo required to update /etc/hosts — authenticating now...${NC}"
    sudo -v
    # Keep sudo alive in background until script finishes
    while true; do sudo -n true; sleep 50; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

# Create directories
mkdir -p "$ISO_DIR" "$IMG_DIR" "$BIN_DIR"

# Step 1: Download cloud image
header "Step 1/15: Cloud Image"
if [[ -f "$CLOUD_IMG_BASE" ]]; then
    SIZE=$(stat -f%z "$CLOUD_IMG_BASE" 2>/dev/null || echo 0)
    if [[ "$SIZE" -gt 500000000 ]]; then
        echo "Cloud image exists: $CLOUD_IMG_BASE"
    else
        rm -f "$CLOUD_IMG_BASE"
    fi
fi

if [[ ! -f "$CLOUD_IMG_BASE" ]]; then
    echo "Downloading Ubuntu 24.04 Cloud Image (~600MB)..."
    curl -L --progress-bar -o "$CLOUD_IMG_BASE" "$CLOUD_IMG_URL"
fi
echo -e "${GREEN}✓${NC} Cloud image ready"

# Step 2: SSH Key
header "Step 2/15: SSH Key"
SSH_KEY_PRIVATE="$HOME/.ssh/k8slab.key"
SSH_KEY_FILE="${SSH_KEY_PRIVATE}.pub"

if [[ ! -f "$SSH_KEY_PRIVATE" ]] || [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Generating SSH key pair..."
    rm -f "$SSH_KEY_PRIVATE" "$SSH_KEY_FILE"
    ssh-keygen -t ed25519 -f "$SSH_KEY_PRIVATE" -N "" -C "k8s-utm-simple-homelab" -q
    chmod 600 "$SSH_KEY_PRIVATE"
    chmod 644 "$SSH_KEY_FILE"
fi
SSH_KEY=$(cat "$SSH_KEY_FILE")
echo -e "${GREEN}✓${NC} SSH key: $SSH_KEY_FILE"

# Step 2.5: Download K8s binaries in background
header "Step 2.5: Download K8s Binaries (Background)"
download_binaries() {
    local log_file="$BIN_DIR/download.log"
    echo "[$(date)] Starting parallel binary downloads..." > "$log_file"
    local pids=()

    bg_download() {
        local url="$1" dest="$2" label="$3"
        if [[ ! -f "$dest" ]]; then
            echo "[$(date)] Downloading $label..." >> "$log_file"
            curl -sL -o "$dest" "$url" 2>>"$log_file" && \
                echo "[$(date)] $label complete" >> "$log_file" || \
                echo "[$(date)] $label FAILED" >> "$log_file" &
            pids+=($!)
        else
            echo "[$(date)] $label already cached" >> "$log_file"
        fi
    }

    bg_download "$ETCD_DOWNLOAD_URL" \
        "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" "etcd v${ETCD_VERSION}"

    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
        bg_download "${K8S_DOWNLOAD_URL}/$bin" "$BIN_DIR/$bin" "$bin v${K8S_VERSION}"
    done

    bg_download "$CONTAINERD_DOWNLOAD_URL" \
        "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" "containerd v${CONTAINERD_VERSION}"

    bg_download "$RUNC_DOWNLOAD_URL" "$BIN_DIR/runc.arm64" "runc v${RUNC_VERSION}"

    bg_download "$CALICO_MANIFEST_URL" "$BIN_DIR/calico.yaml" "calico v${CALICO_VERSION} manifest"

    echo "[$(date)] Waiting for ${#pids[@]} parallel downloads..." >> "$log_file"
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done

    if [[ $failed -gt 0 ]]; then
        echo "[$(date)] WARNING: $failed download(s) failed" >> "$log_file"
    fi
    echo "[$(date)] All downloads complete ($failed failures)" >> "$log_file"
    touch "$BIN_DIR/.download-complete"
}

rm -f "$BIN_DIR/.download-complete"
download_binaries &
DOWNLOAD_PID=$!
echo -e "  Download started in background (PID: $DOWNLOAD_PID)"
echo -e "${GREEN}✓${NC} Binary download running in background"

# Step 3: Create VMs
header "Step 3/15: Creating VMs"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    create_vm "$name" "192.168.64.${ip_suffix}" "$ram_mb" "$vcpu" "$disk_gb" "$SSH_KEY"
done
echo -e "${GREEN}✓${NC} All VMs created"

# Step 4: Restart UTM
header "Step 4/15: Restart UTM"
echo "Restarting UTM to detect new VMs..."
pkill -x UTM 2>/dev/null || true
sleep 2
open -a UTM
sleep 5
echo -e "${GREEN}✓${NC} UTM restarted"

# Step 5: Update Mac /etc/hosts
header "Step 5/15: Update Mac /etc/hosts"
HOSTS_MARKER="# K8s Simple Homelab VMs"
if grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    echo "Hosts entries already exist, skipping..."
else
    echo "Adding jump and vault to /etc/hosts (requires sudo)..."
    sudo tee -a /etc/hosts > /dev/null << 'HOSTS_EOF'

# K8s Simple Homelab VMs
192.168.64.11  vault
192.168.64.12  jump
# End K8s Simple Homelab
HOSTS_EOF
fi
echo -e "${GREEN}✓${NC} Mac /etc/hosts ready"

# Step 6: Setup SSH config
header "Step 6/15: Setup SSH Config"
SSH_CONFIG="$HOME/.ssh/config"
SSH_MARKER="# K8s Simple Homelab"

if grep -q "$SSH_MARKER" "$SSH_CONFIG" 2>/dev/null; then
    echo "SSH config already exists"
else
    echo "Adding SSH config for jump server (bastion host)..."
    cat >> "$SSH_CONFIG" << 'SSH_EOF'

# K8s Simple Homelab - Jump server is the bastion
Host jump
    HostName 192.168.64.12
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    GSSAPIAuthentication no
    PreferredAuthentications publickey
# End K8s Simple Homelab
SSH_EOF
    chmod 600 "$SSH_CONFIG"
fi
echo -e "${GREEN}✓${NC} SSH config ready"

# Step 7: Start all VMs
header "Step 7/15: Starting VMs"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    echo -n "  Starting $name... "
    if utmctl start "$name" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}already running or error${NC}"
    fi
    sleep 2
done
echo -e "${GREEN}✓${NC} All VMs started"

# Step 8: Wait for VMs to boot
header "Step 8/15: Waiting for VMs to Boot"
echo "Polling SSH until VMs are ready..."
echo ""

START_TIME=$(date +%s)
MAX_WAIT=600

CHECK_IPS=("192.168.64.12" "192.168.64.11" "192.168.64.21" "192.168.64.31" "192.168.64.41" "192.168.64.42")
CHECK_NAMES=("jump" "vault" "etcd-1" "master-1" "worker-1" "worker-2")
READY_VMS=""
READY_COUNT=0
JUMP_IS_READY=false

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    
    for i in "${!CHECK_IPS[@]}"; do
        ip="${CHECK_IPS[$i]}"
        name="${CHECK_NAMES[$i]}"
        
        echo "$READY_VMS" | grep -q ":${name}:" && continue
        
        if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -i "$SSH_KEY_PRIVATE" k8s@${ip} "exit 0" &>/dev/null; then
            READY_VMS="${READY_VMS}:${name}:"
            READY_COUNT=$((READY_COUNT + 1))
            [[ "$name" == "jump" ]] && JUMP_IS_READY=true
            printf "\r  %-12s ${GREEN}ready${NC} (%ds)                    \n" "$name" "$ELAPSED"
        fi
    done
    
    printf "\r  [%d/%d VMs ready] %ds elapsed..." "$READY_COUNT" "${#CHECK_IPS[@]}" "$ELAPSED"
    
    if [[ $READY_COUNT -ge ${#CHECK_IPS[@]} ]]; then
        echo ""
        echo -e "${GREEN}✓${NC} All VMs ready in ${ELAPSED}s!"
        break
    fi
    
    if [[ "$JUMP_IS_READY" == "true" ]] && [[ $READY_COUNT -ge 4 ]]; then
        echo ""
        echo -e "${GREEN}✓${NC} ${READY_COUNT} VMs ready (including jump) in ${ELAPSED}s - proceeding"
        break
    fi
    
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        echo ""
        echo -e "${YELLOW}⚠${NC} Timeout after ${MAX_WAIT}s. ${READY_COUNT} VMs ready."
        break
    fi
    
    sleep 3
done

# Step 9: Configure jump server
header "Step 9/15: Configure Jump Server"
echo "Copying SSH key and config to jump server..."

echo -n "  Checking jump connectivity"
JUMP_READY=false
for retry in {1..12}; do
    if ssh -o ConnectTimeout=10 -o BatchMode=yes jump "echo ok" &>/dev/null; then
        echo -e " ${GREEN}OK${NC}"
        JUMP_READY=true
        break
    fi
    echo -n "."
    sleep 5
done
if [[ "$JUMP_READY" != "true" ]]; then
    echo -e " ${RED}FAILED${NC}"
fi

if [[ "$JUMP_READY" != "true" ]]; then
    echo -e "${YELLOW}Jump server not reachable. Configure manually later.${NC}"
else
    echo -n "  Fixing home directory ownership..."
    ssh jump "sudo chown -R k8s:k8s /home/k8s" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}SKIP${NC}"

    echo -n "  Creating .ssh directory..."
    ssh jump "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}SKIP${NC}"

    echo -n "  Copying SSH key..."
    scp "$SSH_KEY_PRIVATE" jump:~/.ssh/k8slab.key 2>/dev/null && \
    ssh jump "chmod 600 ~/.ssh/k8slab.key" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Creating SSH config..."
    ssh jump 'cat > ~/.ssh/config << "SSHCONFIG"
# K8s Simple Homelab VMs
Host vault
    HostName 192.168.64.11
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host etcd-1
    HostName 192.168.64.21
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host master-1
    HostName 192.168.64.31
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host worker-1
    HostName 192.168.64.41
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host worker-2
    HostName 192.168.64.42
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCONFIG
chmod 600 ~/.ssh/config' 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"
fi

echo -e "${GREEN}✓${NC} Jump server configured"

# Copy project files to jump
if [[ "$JUMP_READY" == "true" ]]; then
    echo ""
    echo "Copying project files to jump server..."

    echo -n "  Creating ~/k8s-utm-simple-homelab on jump..."
    ssh jump "mkdir -p ~/k8s-utm-simple-homelab" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying ansible/..."
    scp -r "$PROJECT_DIR/ansible" jump:~/k8s-utm-simple-homelab/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -e "${GREEN}✓${NC} Project files copied to jump:~/k8s-utm-simple-homelab/"
fi

# Step 10: Connectivity Test
header "Step 10/15: Connectivity Test"
echo ""

success_count=0
fail_count=0

printf "  %-12s (%s): " "jump" "192.168.64.12"
if ssh -o ConnectTimeout=30 -o BatchMode=yes \
       jump "echo ok" 2>/dev/null | grep -q "ok"; then
    echo -e "${GREEN}SSH OK${NC}"
    success_count=$((success_count + 1))
    JUMP_OK=true
else
    echo -e "${RED}SSH FAILED${NC}"
    fail_count=$((fail_count + 1))
    JUMP_OK=false
fi

if [[ "$JUMP_OK" == "true" ]]; then
    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
        [[ "$name" == "jump" ]] && continue
        
        ip="192.168.64.${ip_suffix}"
        printf "  %-12s (%s): " "$name" "$ip"
        
        if ssh -o ConnectTimeout=10 -o BatchMode=yes \
               jump "ssh -o ConnectTimeout=5 -o BatchMode=yes ${name} 'echo ok'" 2>/dev/null | grep -q "ok"; then
            echo -e "${GREEN}SSH OK (via jump)${NC}"
            success_count=$((success_count + 1))
        else
            echo -e "${RED}SSH FAILED${NC}"
            fail_count=$((fail_count + 1))
        fi
    done
fi

echo ""
echo "Results: ${success_count}/${#VMS[@]} VMs reachable"

# Step 10.5: Wait for background binary downloads
header "Step 10.5: Wait for Binary Downloads"
if kill -0 $DOWNLOAD_PID 2>/dev/null; then
    echo -n "  Waiting for binary downloads to finish..."
    while kill -0 $DOWNLOAD_PID 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo ""
fi

if [[ -f "$BIN_DIR/.download-complete" ]]; then
    echo -e "${GREEN}✓${NC} All binaries downloaded"
else
    echo -e "${RED}✗${NC} Binary download may have failed - check $BIN_DIR/download.log"
fi

# Copy binaries to jump server
if [[ "$JUMP_OK" == "true" ]] && [[ -f "$BIN_DIR/.download-complete" ]]; then
    echo ""
    echo "Copying binaries to jump server..."

    echo -n "  Creating cache dirs on jump..."
    ssh jump "mkdir -p /tmp/k8s-binaries /tmp/etcd-cache /tmp/containerd-cache" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying K8s binaries..."
    scp "$BIN_DIR/kube-apiserver" "$BIN_DIR/kube-controller-manager" "$BIN_DIR/kube-scheduler" "$BIN_DIR/kubectl" \
        "$BIN_DIR/kubelet" "$BIN_DIR/kube-proxy" \
        jump:/tmp/k8s-binaries/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying etcd tarball..."
    scp "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" \
        jump:/tmp/etcd-cache/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying containerd + runc..."
    scp "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" "$BIN_DIR/runc.arm64" \
        jump:/tmp/containerd-cache/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Copying Calico manifest..."
    scp "$BIN_DIR/calico.yaml" \
        jump:/tmp/ 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    ssh jump "touch /tmp/k8s-binaries/.pre-cached /tmp/etcd-cache/.pre-cached /tmp/containerd-cache/.pre-cached" 2>/dev/null
    echo -e "${GREEN}✓${NC} Binaries pre-cached on jump server"
fi

# Step 11: Setup Vault environment on jump
header "Step 11/15: Setup Vault Environment"
if [[ "$JUMP_OK" == "true" ]]; then
    echo -n "  Adding Vault environment to .bashrc..."
    ssh jump 'grep -q "VAULT_ADDR=" ~/.bashrc 2>/dev/null || cat >> ~/.bashrc << '\''EOF'\''

# Vault environment
export VAULT_ADDR="http://vault:8200"

# Load token from Ansible credentials
export VAULT_TOKEN=$(jq -r .root_token ~/k8s-utm-simple-homelab/ansible/.vault-credentials/vault-init.json 2>/dev/null)

# Unseal vault after vault server reboot (uses first 3 keys)
vault-unseal() {
    echo "Unsealing Vault..."
    local creds="$HOME/k8s-utm-simple-homelab/ansible/.vault-credentials/vault-init.json"
    if [[ ! -f "$creds" ]]; then
        echo "Error: $creds not found"
        return 1
    fi
    for key in $(jq -r '.keys[:3][]' "$creds"); do
        vault operator unseal "$key"
    done
    echo "Done. Check: vault status"
}
EOF' 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}"

    echo -n "  Creating ~/.profile..."
    ssh jump '[[ -f ~/.profile ]] || cat > ~/.profile << '\''EOF'\''
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
EOF' 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}EXISTS${NC}"

    echo -e "${GREEN}✓${NC} Vault environment configured"
fi

# Step 12: Run Vault Full Setup
header "Step 12/15: Run Vault Full Setup"
if [[ "$JUMP_OK" == "true" ]]; then
    echo -n "Waiting for ansible to be installed (cloud-init)..."
    ANSIBLE_WAIT=0
    ANSIBLE_MAX=120
    while ! ssh jump 'which ansible-playbook' &>/dev/null; do
        sleep 5
        ANSIBLE_WAIT=$((ANSIBLE_WAIT + 5))
        echo -n "."
        if [[ $ANSIBLE_WAIT -ge $ANSIBLE_MAX ]]; then
            echo -e " ${RED}TIMEOUT${NC}"
            break
        fi
    done
    
    if ssh jump 'which ansible-playbook' &>/dev/null; then
        echo -e " ${GREEN}OK${NC}"
        echo ""
        
        if ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/vault-full-setup.yml && touch ~/.vault-bootstrapped'; then
            echo ""
            echo -e "${GREEN}✓${NC} Vault setup complete!"
            
            # Step 13: Deploy K8s Certificates
            header "Step 13/15: Deploy K8s Certificates"
            if ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/k8s-certs.yml'; then
                echo ""
                echo -e "${GREEN}✓${NC} Certificates deployed!"
                
                # Step 14: Deploy etcd (single node, no parallel needed)
                header "Step 14a/15: Deploy etcd"
                if ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/etcd-cluster.yml'; then
                    echo ""
                    echo -e "${GREEN}✓${NC} etcd deployed!"
                    
                    # Step 14a.5: Store etcd encryption key in Vault
                    header "Step 14a.5/15: Store etcd encryption key in Vault"
                    if ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/vault-etcd-encryption-key.yml'; then
                        echo ""
                        echo -e "${GREEN}✓${NC} etcd encryption key stored in Vault!"
                    
                        # Step 14b: Deploy Control Plane
                        header "Step 14b/15: Deploy Control Plane"
                        if ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/control-plane.yml'; then
                            echo ""
                            echo -e "${GREEN}✓${NC} Control plane deployed!"
                        
                            # Step 14c: Deploy Worker Nodes
                            header "Step 14c/15: Deploy Worker Nodes"
                            if ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/worker.yml'; then
                                echo ""
                                echo -e "${GREEN}✓${NC} Worker nodes deployed!"
                            
                                # Step 15: Install Calico CNI
                                header "Step 15/15: Install Calico CNI"
                                if ssh jump 'if [[ -f /tmp/calico.yaml ]]; then echo "Using pre-cached calico.yaml"; else curl -sL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml -o /tmp/calico.yaml; fi && \
                                    sed -i "s|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: \"192.168.0.0/16\"|  value: \"10.244.0.0/16\"|" /tmp/calico.yaml && \
                                    kubectl apply -f /tmp/calico.yaml'; then
                                    echo ""
                                    echo "Waiting for nodes to become Ready..."
                                    sleep 30
                                    ssh jump 'kubectl get nodes -o wide'
                                    echo ""
                                    echo -e "${GREEN}✓${NC} Calico CNI installed!"
                                else
                                    echo -e "${RED}✗${NC} Calico installation failed"
                                    echo "  ssh jump && kubectl apply -f /tmp/calico.yaml"
                                fi
                            else
                                echo -e "${RED}✗${NC} Worker deployment failed"
                                echo "  ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/worker.yml'"
                            fi
                        else
                            echo -e "${RED}✗${NC} Control plane deployment failed"
                            echo "  ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/control-plane.yml'"
                        fi
                    else
                        echo -e "${RED}✗${NC} Failed to store etcd encryption key"
                        echo "  ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/vault-etcd-encryption-key.yml'"
                    fi
                else
                    echo -e "${RED}✗${NC} etcd deployment failed"
                    echo "  ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/etcd-cluster.yml'"
                fi
            else
                echo -e "${RED}✗${NC} Certificate deployment failed"
                echo "  ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/k8s-certs.yml'"
            fi
        else
            echo -e "${RED}✗${NC} Vault setup failed"
            echo "  ssh jump 'cd ~/k8s-utm-simple-homelab/ansible && ansible-playbook -i inventory/ playbooks/vault-full-setup.yml'"
        fi
    fi
fi

# Summary
header "Setup Complete!"
echo ""
if [[ $fail_count -eq 0 ]]; then
    echo -e "${GREEN}All VMs are up and running!${NC}"
else
    echo -e "${YELLOW}Some VMs may need more time to boot.${NC}"
fi
echo ""
echo "SSH access (bastion architecture):"
echo "  Direct to jump:    ssh jump"
echo "  From jump:         ssh master-1, ssh worker-1, etc."
echo ""
echo "Console access: SSH key only (~/.ssh/k8slab.key)"
echo ""
echo "VM Status:"
echo "  utmctl list"
echo ""
echo "IP Addresses:"
for vm_def in "${VMS[@]}"; do
    IFS=':' read -r name ip_suffix ram_mb vcpu disk_gb <<< "$vm_def"
    printf "  %-12s 192.168.64.%s\n" "$name" "$ip_suffix"
done

# Print total elapsed time
SCRIPT_END_TIME=$(date +%s)
ELAPSED=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS_REM=$((ELAPSED % 60))
echo ""
echo -e "${BLUE}Total time: ${MINUTES}m ${SECONDS_REM}s${NC}"
