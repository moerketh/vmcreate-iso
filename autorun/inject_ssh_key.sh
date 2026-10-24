#!/bin/bash
# Read the SSH public key from host-to-guest KVP pool 0 and install it for
# the vmcreate user. This is the only channel that must exist before SSH is
# usable: the host writes the key right after VM start, hv_kvp_daemon
# materializes the pool file a moment later, and the host then connects
# over vsock (hvc.exe nc -t vsock <guid> 22) using the matching private key.
#
# On hypervisors without host->guest KVP (e.g. KVM) the pool file never
# appears; this script waits POOL_WAIT_ATTEMPTS seconds and gives up
# quietly. That is fine for now — VMCreate drives KVM guests differently.
#
# Test hooks: FUNCTIONS_SRC, KVP_POOL, VMCREATE_HOME, POOL_WAIT_ATTEMPTS,
# KEY_WAIT_ATTEMPTS and POLL_INTERVAL are overridable (used by
# test/inject_ssh_key.bats).
source "${FUNCTIONS_SRC:-/opt/lib/functions.sh}"

POOL="${KVP_POOL:-/var/lib/hyperv/.kvp_pool_0}"
HOME_DIR="${VMCREATE_HOME:-/home/vmcreate}"
POOL_WAIT_ATTEMPTS="${POOL_WAIT_ATTEMPTS:-30}"
KEY_WAIT_ATTEMPTS="${KEY_WAIT_ATTEMPTS:-60}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
KEY_SIZE=512
VALUE_SIZE=2048

# Wait for KVP pool file to appear
for i in $(seq 1 "$POOL_WAIT_ATTEMPTS"); do
    [ -f "$POOL" ] && break
    sleep "$POLL_INTERVAL"
done
[ -f "$POOL" ] || { log "WARN" "inject_ssh_key: KVP pool file never appeared"; exit 0; }

# Retry reading the key. Never cache an empty result: if the daemon has not
# written the key yet, re-read until it has. A matched name whose value is
# empty or fails the key-material gate below is treated the same way — a
# torn or partially written record must not end the scan with "not found"
# while retries remain (the daemon may still be rewriting the pool).
pubkey=""
found=0
for attempt in $(seq 1 "$KEY_WAIT_ATTEMPTS"); do
    index=0
    while true; do
        offset=$((index * (KEY_SIZE + VALUE_SIZE)))
        key=$(read_kvp_field "$POOL" "$offset" "$KEY_SIZE")
        [ -z "$key" ] && break
        if [ "$key" = "VMCREATE_SSH_PUBKEY" ]; then
            value_offset=$((offset + KEY_SIZE))
            pubkey=$(read_kvp_field "$POOL" "$value_offset" "$VALUE_SIZE")
            case "$pubkey" in
                ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*)
                    found=1
                    break 2
                    ;;
            esac
        fi
        index=$((index + 1))
    done
    if (( attempt % 10 == 0 )); then
        log "INFO" "inject_ssh_key: waiting for VMCREATE_SSH_PUBKEY... ${attempt}s"
    fi
    sleep "$POLL_INTERVAL"
done

if (( ! found )); then
    log "WARN" "inject_ssh_key: VMCREATE_SSH_PUBKEY not found — no SSH access this boot"
    exit 0
fi

# Accept only recognizable key material: the value must look like a public
# key, not stale heap bytes that happened to sit under the right name.
case "$pubkey" in
    ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) ;;
    *)
        log "WARN" "inject_ssh_key: VMCREATE_SSH_PUBKEY value is not a public key — ignoring"
        exit 0
        ;;
esac

mkdir -p "$HOME_DIR/.ssh"
echo "$pubkey" > "$HOME_DIR/.ssh/authorized_keys"
chown -R vmcreate:vmcreate "$HOME_DIR/.ssh" 2>/dev/null || true
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
log "INFO" "SSH public key injected for vmcreate user after ${attempt} attempt(s)"
