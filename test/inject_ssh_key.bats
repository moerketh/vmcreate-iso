#!/usr/bin/env bats

# Tests for autorun/inject_ssh_key.sh — the only boot-time logic in the ISO.
# Runs the REAL script (never a copy) with its test hooks:
#   FUNCTIONS_SRC, KVP_POOL, VMCREATE_HOME, POOL/KEY_WAIT_ATTEMPTS, POLL_INTERVAL

load 'test_helper'

INJECT="$PROJECT_ROOT/autorun/inject_ssh_key.sh"

run_inject() {
    # Mock tee: log() appends to /var/log/vmcreate-iso.log, which is not
    # writable outside the real (root) boot environment.
    tee() { cat; }
    export -f tee
    KVP_POOL="$1" \
    VMCREATE_HOME="$TEST_TEMP_DIR/home" \
    FUNCTIONS_SRC="$PROJECT_ROOT/lib/functions.sh" \
    POOL_WAIT_ATTEMPTS=1 KEY_WAIT_ATTEMPTS=2 POLL_INTERVAL=0 \
    run bash "$INJECT"
}

@test "installs the pubkey from a later slot and strips garbage after NUL" {
    run_inject "$PROJECT_ROOT/test/fixtures/ssh_key_pool"
    [ "$status" -eq 0 ]

    local auth="$TEST_TEMP_DIR/home/.ssh/authorized_keys"
    [ -f "$auth" ]
    # Exactly the clean value — the ff02::/castprefix heap scraps behind
    # the NUL must NOT be glued onto the key.
    [ "$(cat "$auth")" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleTestKeyVmcreate user@host" ]
    [ "$(stat -c '%a' "$TEST_TEMP_DIR/home/.ssh")" = "700" ]
    [ "$(stat -c '%a' "$auth")" = "600" ]
}

@test "ignores a VMCREATE_SSH_PUBKEY value that is not key material" {
    run_inject "$PROJECT_ROOT/test/fixtures/bad_key_pool"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/home/.ssh/authorized_keys" ]
}

@test "scans past a torn record (name set, value empty) to a later valid one" {
    # Record 0 has the key name but an empty value (daemon mid-write);
    # record 1 holds the real key. The scan must not stop at the torn
    # record — a matched name whose value fails the gate is retried/past,
    # honoring the "never cache an empty result" contract.
    run_inject "$PROJECT_ROOT/test/fixtures/torn_key_pool"
    [ "$status" -eq 0 ]

    local auth="$TEST_TEMP_DIR/home/.ssh/authorized_keys"
    [ -f "$auth" ]
    [ "$(cat "$auth")" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleTestKeyVmcreate user@host" ]
}

@test "gives up quietly when the pool file never appears (KVM: no KVP)" {
    KVP_POOL="$TEST_TEMP_DIR/no-such-pool" \
    VMCREATE_HOME="$TEST_TEMP_DIR/home" \
    FUNCTIONS_SRC="$PROJECT_ROOT/lib/functions.sh" \
    POOL_WAIT_ATTEMPTS=2 KEY_WAIT_ATTEMPTS=1 POLL_INTERVAL=0 \
    run bash "$INJECT"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/home/.ssh" ]
}

@test "gives up quietly when the pool has no SSH key" {
    run_inject "$PROJECT_ROOT/test/fixtures/dirty_kvp_pool"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/home/.ssh/authorized_keys" ]
}
