#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# NSO A2 - Fedora Host Network Configuration
#
# Purpose:
#   Configure and validate host-side networking required by
#   the KVM/libvirt NSO lab.
#
# This script DOES NOT:
#   - create VMs
#   - delete VMs
#   - configure IP addresses inside VMs
#   - install Flask / HAProxy / Nginx / SNMP
#
# Expected topology:
#
# Fedora Host
#
#   virbr0
#   192.168.122.1/24
#   libvirt "default"
#   NAT -> Internet
#
#        |
#        +-- bastionET2598 external0
#        +-- HAproxy       external0
#        +-- devA          external0
#        +-- devB          external0
#        +-- devC          external0
#
#
#   virbr1 (name may differ)
#   10.0.1.1/27
#   libvirt "site-local"
#
#        |
#        +-- bastionET2598 internal0
#        +-- HAproxy       internal0
#        +-- devA          internal0
#        +-- devB          internal0
#        +-- devC          internal0
#
# ============================================================


VM_LIST=(
    bastionET2598
    HAproxy
    devA
    devB
    devC
)


# ============================================================
# Helper functions
# ============================================================

section()
{
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}


error()
{
    echo "ERROR: $1" >&2
}


warning()
{
    echo "WARNING: $1" >&2
}


# ============================================================
# 1. Check required commands
# ============================================================

section "1. Checking required commands"


COMMANDS=(
    virsh
    firewall-cmd
    sysctl
    ip
    bridge
)


for cmd in "${COMMANDS[@]}"
do

    if ! command -v "$cmd" >/dev/null 2>&1
    then

        error "Missing command: $cmd"

        exit 1

    fi

done


echo "Required commands available."


# ============================================================
# 2. Check Internet on Fedora host
# ============================================================

section "2. Checking Fedora host Internet access"


if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
then

    echo "Fedora host Internet: OK"

else

    warning "Fedora host cannot ping 8.8.8.8."
    warning "VM Internet access may also fail."

fi


# ============================================================
# 3. Enable IPv4 forwarding
# ============================================================

section "3. Enabling IPv4 forwarding"


CURRENT_FORWARD="$(
    sysctl -n net.ipv4.ip_forward
)"


if [[ "$CURRENT_FORWARD" != "1" ]]
then

    echo "Enabling IPv4 forwarding..."

    sudo sysctl -w net.ipv4.ip_forward=1

else

    echo "IPv4 forwarding already enabled."

fi


echo "net.ipv4.ip_forward=1" |
    sudo tee /etc/sysctl.d/99-nso-ip-forward.conf \
    >/dev/null


sudo sysctl --system >/dev/null


echo "IPv4 forwarding: $(
    sysctl -n net.ipv4.ip_forward
)"


# ============================================================
# 4. Check default libvirt network
# ============================================================

section "4. Checking libvirt default network"


if ! sudo virsh net-info default >/dev/null 2>&1
then

    error "libvirt network 'default' does not exist."

    echo
    echo "setup_vm.sh expects/provides the default libvirt network."
    echo

    exit 1

fi


if sudo virsh net-list --name |
    grep -Fxq "default"
then

    echo "default network already active."

else

    echo "Starting default network..."

    sudo virsh net-start default

fi


sudo virsh net-autostart default \
    >/dev/null 2>&1 || true


# ============================================================
# 5. Validate default network NAT configuration
# ============================================================

section "5. Checking default NAT configuration"


DEFAULT_XML="$(
    sudo virsh net-dumpxml default
)"


if grep -q "forward mode='nat'" <<< "$DEFAULT_XML" ||
   grep -q 'forward mode="nat"' <<< "$DEFAULT_XML"
then

    echo "default network NAT: OK"

else

    error "default network is NOT configured as NAT."

    echo
    echo "Expected:"
    echo
    echo "    <forward mode='nat'/>"
    echo
    echo "Current configuration:"
    echo
    sudo virsh net-dumpxml default

    exit 1

fi


# ============================================================
# 6. Get default bridge
# ============================================================

section "6. Checking default bridge"


DEFAULT_BRIDGE="$(
    sudo virsh net-info default |
    awk '/Bridge:/ {print $2}'
)"


if [[ -z "$DEFAULT_BRIDGE" ]]
then

    error "Unable to determine bridge for default network."

    exit 1

fi


echo "default bridge: $DEFAULT_BRIDGE"


if ! ip link show "$DEFAULT_BRIDGE" >/dev/null 2>&1
then

    error "$DEFAULT_BRIDGE does not exist."

    exit 1

fi


ip addr show "$DEFAULT_BRIDGE"


# ============================================================
# 7. Check site-local network
# ============================================================

section "7. Checking site-local network"


if ! sudo virsh net-info site-local >/dev/null 2>&1
then

    error "site-local network does not exist."

    echo
    echo "Run setup_vm.sh first, or define site-local.xml manually."
    echo

    exit 1

fi


if sudo virsh net-list --name |
    grep -Fxq "site-local"
then

    echo "site-local already active."

else

    echo "Starting site-local..."

    sudo virsh net-start site-local

fi


sudo virsh net-autostart site-local \
    >/dev/null 2>&1 || true


SITE_BRIDGE="$(
    sudo virsh net-info site-local |
    awk '/Bridge:/ {print $2}'
)"


echo "site-local bridge: $SITE_BRIDGE"


# ============================================================
# 8. Validate site-local address
# ============================================================

section "8. Checking site-local address"


if ip addr show "$SITE_BRIDGE" |
    grep -q "10.0.1.1/27"
then

    echo "site-local address: 10.0.1.1/27 OK"

else

    error "$SITE_BRIDGE does not have 10.0.1.1/27"

    ip addr show "$SITE_BRIDGE"

    exit 1

fi


# ============================================================
# 9. Configure firewalld libvirt zone
# ============================================================

section "9. Configuring firewalld libvirt zone"


if ! systemctl is-active --quiet firewalld
then

    warning "firewalld is not running."

else

    echo "Enabling forwarding in libvirt zone..."

    sudo firewall-cmd \
        --zone=libvirt \
        --add-forward \
        --permanent \
        >/dev/null


    echo "Enabling masquerading in libvirt zone..."

    sudo firewall-cmd \
        --zone=libvirt \
        --add-masquerade \
        --permanent \
        >/dev/null


    sudo firewall-cmd --reload \
        >/dev/null


    echo
    sudo firewall-cmd \
        --zone=libvirt \
        --list-all

fi


# ============================================================
# 10. Verify masquerading
# ============================================================

section "10. Checking masquerading"


if systemctl is-active --quiet firewalld
then

    MASQUERADE="$(
        sudo firewall-cmd \
            --zone=libvirt \
            --query-masquerade
    )"


    echo "Masquerade: $MASQUERADE"


    FORWARD="$(
        sudo firewall-cmd \
            --zone=libvirt \
            --query-forward
    )"


    echo "Forward: $FORWARD"

fi


# ============================================================
# 11. Check VM definitions
# ============================================================

section "11. Checking VM network definitions"


for vm in "${VM_LIST[@]}"
do

    echo
    echo "----- $vm -----"


    if ! sudo virsh dominfo "$vm" >/dev/null 2>&1
    then

        warning "$vm does not exist."

        continue

    fi


    sudo virsh domiflist "$vm"

done


# ============================================================
# 12. Check expected networks per VM
# ============================================================

section "12. Validating VM interfaces"


FAILED=0


for vm in "${VM_LIST[@]}"
do

    if ! sudo virsh dominfo "$vm" >/dev/null 2>&1
    then

        FAILED=1

        continue

    fi


    VM_NETWORKS="$(
        sudo virsh domiflist "$vm" |
        awk 'NR > 2 {print $3}'
    )"


    if grep -Fxq "default" <<< "$VM_NETWORKS"
    then

        echo "$vm -> default: OK"

    else

        warning "$vm has no default network interface."

        FAILED=1

    fi


    if grep -Fxq "site-local" <<< "$VM_NETWORKS"
    then

        echo "$vm -> site-local: OK"

    else

        warning "$vm has no site-local interface."

        FAILED=1

    fi

done


# ============================================================
# 13. Show Linux bridge attachment
# ============================================================

section "13. Current bridge attachment"


bridge link || true


# ============================================================
# 14. Detect broken external tap interfaces
# ============================================================

section "14. Checking external tap interfaces"


BROKEN_EXTERNAL=0


for vm in "${VM_LIST[@]}"
do

    if ! sudo virsh dominfo "$vm" >/dev/null 2>&1
    then
        continue
    fi


    TAP="$(
        sudo virsh domiflist "$vm" |
        awk '$3=="default" {print $1; exit}'
    )"


    if [[ -z "$TAP" ]]
    then

        warning "$vm: no default interface"

        BROKEN_EXTERNAL=1

        continue

    fi


    if bridge link |
        grep -E "^[0-9]+: ${TAP}:" |
        grep -q "master ${DEFAULT_BRIDGE}"
    then

        echo "$vm: $TAP -> $DEFAULT_BRIDGE OK"

    else

        warning "$vm: $TAP is NOT attached to $DEFAULT_BRIDGE"

        BROKEN_EXTERNAL=1

    fi

done


# ============================================================
# 15. Detect internal tap interfaces
# ============================================================

section "15. Checking internal tap interfaces"


BROKEN_INTERNAL=0


for vm in "${VM_LIST[@]}"
do

    if ! sudo virsh dominfo "$vm" >/dev/null 2>&1
    then
        continue
    fi


    TAP="$(
        sudo virsh domiflist "$vm" |
        awk '$3=="site-local" {print $1; exit}'
    )"


    if [[ -z "$TAP" ]]
    then

        warning "$vm: no site-local interface"

        BROKEN_INTERNAL=1

        continue

    fi


    if bridge link |
        grep -E "^[0-9]+: ${TAP}:" |
        grep -q "master ${SITE_BRIDGE}"
    then

        echo "$vm: $TAP -> $SITE_BRIDGE OK"

    else

        warning "$vm: $TAP is NOT attached to $SITE_BRIDGE"

        BROKEN_INTERNAL=1

    fi

done


# ============================================================
# 16. Optional repair of libvirt interface attachment
# ============================================================

section "16. Bridge status"


if [[ "$BROKEN_EXTERNAL" -eq 1 ]]
then

    warning "One or more external VM interfaces are not attached"
    warning "to ${DEFAULT_BRIDGE}."

    echo
    echo "Recommended repair:"
    echo
    echo "    sudo virsh net-destroy default"
    echo "    sudo virsh net-start default"
    echo
    echo "Then restart the affected VMs:"
    echo
    echo "    for vm in bastionET2598 HAproxy devA devB devC; do"
    echo '        sudo virsh reboot "$vm"'
    echo "    done"
    echo

else

    echo "External bridge attachment: OK"

fi


if [[ "$BROKEN_INTERNAL" -eq 1 ]]
then

    warning "Internal bridge attachment problem detected."

else

    echo "Internal bridge attachment: OK"

fi

#-------------------------------------------------------------
# Enable the firewall in the host
#-------------------------------------------------------------

sudo iptables -I FORWARD 1 \
    -i virbr0 \
    -o wlp15s0 \
    -j ACCEPT

sudo iptables -I FORWARD 1 \
    -i wlp15s0 \
    -o virbr0 \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT


# ============================================================
# 17. Final report
# ============================================================

section "17. Final network report"


echo "Host Internet interface:"
ip route show default


echo
echo "IPv4 forwarding:"
sysctl net.ipv4.ip_forward


echo
echo "Libvirt networks:"
sudo virsh net-list --all


echo
echo "Default network:"
sudo virsh net-info default


echo
echo "Site-local network:"
sudo virsh net-info site-local


echo
echo "Expected VM IP configuration:"
echo
echo "                    External             Internal"
echo "---------------------------------------------------------"
echo "bastionET2598      192.168.122.20       10.0.1.5"
echo "HAproxy            192.168.122.21       10.0.1.10"
echo "devA               192.168.122.31       10.0.1.11"
echo "devB               192.168.122.32       10.0.1.12"
echo "devC               192.168.122.33       10.0.1.13"


echo
echo "============================================================"


if [[ "$FAILED" -eq 0 &&
      "$BROKEN_EXTERNAL" -eq 0 &&
      "$BROKEN_INTERNAL" -eq 0 ]]
then

    echo "HOST NETWORK STATUS: OK"

else

    echo "HOST NETWORK STATUS: ATTENTION REQUIRED"

fi


echo "============================================================"
