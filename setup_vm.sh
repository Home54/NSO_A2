#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# NSO A2 KVM Lab Setup
#
# Fedora + libvirt + virt-install + cloud-init
#
# All VMs use STATIC IP addresses.
#
# External/default network:
#   192.168.122.0/24
#
# Internal/site-local network:
#   10.0.1.0/27
#
# Topology:
#
#                       Fedora Host
#                           |
#                  default / NAT
#                 192.168.122.0/24
#                           |
#     +------------+--------+--------+---------+---------+
#     |            |                 |         |         |
#  Bastion      HAproxy            devA      devB      devC
#  .20           .21               .31       .32       .33
#     |            |                 |         |         |
#     +------------+-----------------+---------+---------+
#                           |
#                     site-local
#                     10.0.1.0/27
#                           |
#      +------------+-------+-------+--------+--------+
#      |            |               |        |        |
#   Bastion      HAproxy          devA     devB     devC
#   .5           .10              .11      .12      .13
#
# SSH/Ansible path:
#
# Host -> bastionET2598 -> HAproxy/devA/devB/devC
#
# ============================================================


# ------------------------------------------------------------
# General configuration
# ------------------------------------------------------------
# Project asset layout:
#   vm/images/      -> Ubuntu cloud base image
#   vm/iso/         -> generated cloud-init seed ISO files
#   vm/cloud-init/  -> generated user-data/meta-data/network-config
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="${SCRIPT_DIR}"

VM_DIR="${WORKDIR}/vm"
BASE_IMAGE_DIR="${VM_DIR}/images"
SEED_DIR="${VM_DIR}/iso"
CLOUD_INIT_DIR="${VM_DIR}/cloud-init"

LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"

BASE_IMAGE="${BASE_IMAGE_DIR}/focal-server-cloudimg-amd64.img"

IMAGE_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"

NETWORK_XML="${SCRIPT_DIR}/site-local.xml"

SSH_KEY="${HOME}/.ssh/nso_key"

SSH_CONFIG_DIR="${HOME}/.ssh/config.d"

SSH_CONFIG="${SSH_CONFIG_DIR}/nso_assignment"

RAM=1024

VCPUS=1

DISK_SIZE="8G"


# ------------------------------------------------------------
# External network configuration
# ------------------------------------------------------------

EXT_PREFIX="24"

EXT_GATEWAY="192.168.122.1"

EXT_DNS="1.1.1.1"

declare -A EXT_IP=(
    [bastionET2598]="192.168.122.20"
    [HAproxy]="192.168.122.21"
    [devA]="192.168.122.31"
    [devB]="192.168.122.32"
    [devC]="192.168.122.33"
)


# ------------------------------------------------------------
# Internal network configuration
# ------------------------------------------------------------

INT_PREFIX="27"

declare -A INT_IP=(
    [bastionET2598]="10.0.1.5"
    [HAproxy]="10.0.1.10"
    [devA]="10.0.1.11"
    [devB]="10.0.1.12"
    [devC]="10.0.1.13"
)


# ------------------------------------------------------------
# Static MAC addresses
# ------------------------------------------------------------

declare -A EXT_MAC=(
    [bastionET2598]="52:54:00:aa:00:05"
    [HAproxy]="52:54:00:aa:00:10"
    [devA]="52:54:00:aa:00:11"
    [devB]="52:54:00:aa:00:12"
    [devC]="52:54:00:aa:00:13"
)

declare -A INT_MAC=(
    [bastionET2598]="52:54:00:10:01:05"
    [HAproxy]="52:54:00:10:01:10"
    [devA]="52:54:00:10:01:11"
    [devB]="52:54:00:10:01:12"
    [devC]="52:54:00:10:01:13"
)


VM_LIST=(
    bastionET2598
    HAproxy
    devA
    devB
    devC
)


# ------------------------------------------------------------
# Check commands
# ------------------------------------------------------------

echo "=============================================="
echo "Checking required commands"
echo "=============================================="

for cmd in \
    virsh \
    virt-install \
    qemu-img \
    cloud-localds \
    curl \
    ssh-keygen

do

    if ! command -v "$cmd" >/dev/null 2>&1
    then
        echo "ERROR: missing command: $cmd"
        exit 1
    fi

done


# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------

mkdir -p "$WORKDIR"
mkdir -p "$VM_DIR"
mkdir -p "$BASE_IMAGE_DIR"
mkdir -p "$SEED_DIR"
mkdir -p "$CLOUD_INIT_DIR"
mkdir -p "$SSH_CONFIG_DIR"
mkdir -p "${HOME}/.ssh"


# ------------------------------------------------------------
# SSH key
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Checking SSH key"
echo "=============================================="

if [[ ! -f "$SSH_KEY" ]]
then

    ssh-keygen \
        -t ed25519 \
        -N "" \
        -f "$SSH_KEY"

fi

PUBKEY="$(cat "${SSH_KEY}.pub")"


# ------------------------------------------------------------
# Remove old VMs
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Removing old VMs"
echo "=============================================="

for vm in "${VM_LIST[@]}"
do

    if sudo virsh dominfo "$vm" >/dev/null 2>&1
    then

        echo "Removing $vm"

        sudo virsh destroy "$vm" 2>/dev/null || true

        sudo virsh undefine \
            "$vm" \
            --remove-all-storage \
            --nvram \
            2>/dev/null || \
        sudo virsh undefine \
            "$vm" \
            --remove-all-storage \
            2>/dev/null || true

    fi

    sudo rm -f "${LIBVIRT_IMAGE_DIR}/${vm}.qcow2"

    rm -f "${SEED_DIR}/${vm}-seed.iso"
    rm -f "${CLOUD_INIT_DIR}/${vm}-user-data"
    rm -f "${CLOUD_INIT_DIR}/${vm}-meta-data"
    rm -f "${CLOUD_INIT_DIR}/${vm}-network-config"

done


# ------------------------------------------------------------
# Check default network
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Checking default network"
echo "=============================================="

if ! sudo virsh net-info default >/dev/null 2>&1
then

    echo "ERROR: libvirt default network does not exist."
    exit 1

fi

if ! sudo virsh net-list --name | grep -Fxq "default"
then
    sudo virsh net-start default
fi

sudo virsh net-autostart default >/dev/null 2>&1 || true


# ------------------------------------------------------------
# Recreate site-local network
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Creating site-local network"
echo "=============================================="

if sudo virsh net-info site-local >/dev/null 2>&1
then

    sudo virsh net-destroy site-local 2>/dev/null || true
    sudo virsh net-undefine site-local 2>/dev/null || true

fi

if [[ ! -f "$NETWORK_XML" ]]
then
    echo "ERROR: missing network XML:"
    echo "$NETWORK_XML"
    exit 1
fi

sudo virsh net-define "$NETWORK_XML"
sudo virsh net-start site-local
sudo virsh net-autostart site-local


# ------------------------------------------------------------
# Download cloud image
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Checking Ubuntu 20.04 cloud image"
echo "=============================================="

if [[ ! -f "$BASE_IMAGE" ]]
then

    curl \
        -L \
        --fail \
        "$IMAGE_URL" \
        -o "$BASE_IMAGE"

fi


echo
echo "Base image info:"
qemu-img info "$BASE_IMAGE" | head


# ------------------------------------------------------------
# Generate cloud-init
# ------------------------------------------------------------

create_cloudinit() {

    local NAME="$1"

    local USERDATA="${CLOUD_INIT_DIR}/${NAME}-user-data"
    local METADATA="${CLOUD_INIT_DIR}/${NAME}-meta-data"
    local NETCFG="${CLOUD_INIT_DIR}/${NAME}-network-config"
    local SEED="${SEED_DIR}/${NAME}-seed.iso"

    cat > "$USERDATA" <<EOF
#cloud-config

hostname: ${NAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    groups:
      - sudo
    shell: /bin/bash
    sudo:
      - ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${PUBKEY}

ssh_pwauth: false
disable_root: true

packages:
  - openssh-server
  - python3
  - python3-apt
  - curl

runcmd:
  - systemctl enable ssh
  - systemctl restart ssh
EOF


    cat > "$METADATA" <<EOF
instance-id: ${NAME}
local-hostname: ${NAME}
EOF


    cat > "$NETCFG" <<EOF
version: 2

ethernets:

  external0:
    match:
      macaddress: "${EXT_MAC[$NAME]}"
    set-name: external0
    dhcp4: false

    addresses:
      - ${EXT_IP[$NAME]}/${EXT_PREFIX}

    routes:
      - to: 0.0.0.0/0
        via: ${EXT_GATEWAY}

    nameservers:
      addresses:
        - ${EXT_DNS}
        - 8.8.8.8


  internal0:
    match:
      macaddress: "${INT_MAC[$NAME]}"
    set-name: internal0
    dhcp4: false

    addresses:
      - ${INT_IP[$NAME]}/${INT_PREFIX}
EOF


    rm -f "$SEED"

    cloud-localds \
        --network-config="$NETCFG" \
        "$SEED" \
        "$USERDATA" \
        "$METADATA"
}


# ------------------------------------------------------------
# Create VM
# ------------------------------------------------------------

create_vm() {

    local NAME="$1"

    local DISK="${LIBVIRT_IMAGE_DIR}/${NAME}.qcow2"
    local SEED="${SEED_DIR}/${NAME}-seed.iso"


    echo
    echo "=============================================="
    echo "Creating VM: $NAME"
    echo "=============================================="


    create_cloudinit "$NAME"


    sudo qemu-img create \
        -f qcow2 \
        -F qcow2 \
        -b "$BASE_IMAGE" \
        "$DISK" \
        "$DISK_SIZE"


    sudo virt-install \
        --name "$NAME" \
        --memory "$RAM" \
        --vcpus "$VCPUS" \
        --disk "path=${DISK},format=qcow2,bus=virtio" \
        --disk "path=${SEED},device=cdrom" \
        --osinfo detect=on,require=off \
        --network "network=default,model=virtio,mac=${EXT_MAC[$NAME]}" \
        --network "network=site-local,model=virtio,mac=${INT_MAC[$NAME]}" \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole


    sudo virsh autostart "$NAME" >/dev/null

}


# ------------------------------------------------------------
# Create all VMs
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Creating all VMs"
echo "=============================================="

for vm in "${VM_LIST[@]}"
do
    create_vm "$vm"
done


# ------------------------------------------------------------
# SSH config
# ------------------------------------------------------------

echo
echo "=============================================="
echo "Generating SSH config"
echo "=============================================="

cat > "$SSH_CONFIG" <<EOF
Host bastionET2598
    HostName ${EXT_IP[bastionET2598]}
    User ubuntu
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new


Host HAproxy
    HostName ${INT_IP[HAproxy]}
    User ubuntu
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    ProxyJump bastionET2598
    StrictHostKeyChecking accept-new


Host devA
    HostName ${INT_IP[devA]}
    User ubuntu
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    ProxyJump bastionET2598
    StrictHostKeyChecking accept-new


Host devB
    HostName ${INT_IP[devB]}
    User ubuntu
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    ProxyJump bastionET2598
    StrictHostKeyChecking accept-new


Host devC
    HostName ${INT_IP[devC]}
    User ubuntu
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    ProxyJump bastionET2598
    StrictHostKeyChecking accept-new
EOF

chmod 600 "$SSH_CONFIG"


# ------------------------------------------------------------
# Include config.d
# ------------------------------------------------------------

touch "${HOME}/.ssh/config"
chmod 600 "${HOME}/.ssh/config"

if ! grep -Fqx \
    "Include ~/.ssh/config.d/*" \
    "${HOME}/.ssh/config"
then

    TMP="$(mktemp)"

    {
        echo "Include ~/.ssh/config.d/*"
        echo
        cat "${HOME}/.ssh/config"
    } > "$TMP"

    mv "$TMP" "${HOME}/.ssh/config"

    chmod 600 "${HOME}/.ssh/config"

fi

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo "NSO LAB SETUP COMPLETE"
echo "============================================================"

echo
echo "External static IPs:"
echo

for vm in "${VM_LIST[@]}"
do
    printf "%-16s %s\n" "$vm" "${EXT_IP[$vm]}"
done


echo
echo "Internal static IPs:"
echo

for vm in "${VM_LIST[@]}"
do
    printf "%-16s %s\n" "$vm" "${INT_IP[$vm]}"
done


echo
echo "Libvirt networks:"
sudo virsh net-list --all


echo
echo "VMs:"
sudo virsh list --all


echo
echo "SSH config:"
echo "$SSH_CONFIG"


echo
echo "After cloud-init finishes, test:"
echo

echo "ssh bastionET2598"
echo "ssh HAproxy"
echo "ssh devA"
echo "ssh devB"
echo "ssh devC"


echo
echo "Check Internet access:"
echo

echo "ssh devA 'ping -c 2 8.8.8.8'"
echo "ssh devA 'curl -I https://archive.ubuntu.com'"


echo
echo "Then:"
echo

echo "ansible -i hosts all -m ping"

echo

echo "ansible-playbook -i hosts site.yaml"

echo
echo "============================================================"
