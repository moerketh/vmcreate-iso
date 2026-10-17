#!/bin/bash
# Read the SSH public key from host-to-guest KVP pool 0 and install it for
# the ubuntu user. This is the only channel that must exist before SSH is
# usable: the host writes the key right after VM start, hv_kvp_daemon
# materializes the pool file a moment later, and the host then connects
# over vsock (hvc.exe nc -t vsock <guid> 22) using the matching private key.
source /opt/lib/functions.sh

POOL="/var/lib/hyperv/.kvp_pool_0"
KEY_SIZE=512
VALUE_SIZE=2048

# Wait for KVP pool file to appear (up to 30s)
for i in $(seq 1 30); do
    [ -f "$POOL" ] && break
    sleep 1
done
[ -f "$POOL" ] || { log "WARN" "inject_ssh_key: KVP pool file never appeared"; exit 0; }

# Retry reading the key for up to 60s. Never cache an empty result: if the
# daemon has not written the key yet, re-read until it has.
pubkey=""
for attempt in $(seq 1 60); do
    index=0
    while true; do
        offset=$((index * (KEY_SIZE + VALUE_SIZE)))
        key=$(read_kvp_field "$POOL" "$offset" "$KEY_SIZE")
        [ -z "$key" ] && break
        if [ "$key" = "VMCREATE_SSH_PUBKEY" ]; then
            value_offset=$((offset + KEY_SIZE))
            pubkey=$(read_kvp_field "$POOL" "$value_offset" "$VALUE_SIZE")
            break 2
        fi
        index=$((index + 1))
    done
    if (( attempt % 10 == 0 )); then
        log "INFO" "inject_ssh_key: waiting for VMCREATE_SSH_PUBKEY... ${attempt}s"
    fi
    sleep 1
done

if [ -n "$pubkey" ]; then
    mkdir -p /home/ubuntu/.ssh
    echo "$pubkey" > /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    log "INFO" "SSH public key injected for ubuntu user after ${attempt}s"
else
    log "WARN" "inject_ssh_key: VMCREATE_SSH_PUBKEY not found after 60s — no SSH access this boot"
fi
