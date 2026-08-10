for vm in bastionET2598 HAproxy devA devB devC; do
    sudo virsh start "$vm" 2>/dev/null || echo "$vm Already lauched or failed"
done

sudo virsh list --all
