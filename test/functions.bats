#!/usr/bin/env bats

# BATS tests for the minimal guest library.
# Sources the real lib/functions.sh (the FUNCTIONS_SH_LOADED guard makes
# repeated sourcing a no-op). Never paste an inline copy here: the copy
# drifts from the real code, which is how the first-NUL reader bug
# survived every test run in the old repo.

load 'test_helper'

@test "log function outputs correct format for INFO level" {
    source "$PROJECT_ROOT/lib/functions.sh"

    # Real log pipes through `tee -a /var/log/vmcreate-iso.log`, which can
    # fail on permission-restricted CI runners — mock it.
    tee() { cat; }
    export -f tee

    run log "INFO" "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[INFO\] ]] && [[ "$output" =~ Test\ message ]]
}

@test "log function outputs correct format for WARN level" {
    source "$PROJECT_ROOT/lib/functions.sh"

    tee() { cat; }
    export -f tee

    run log "WARN" "Warning test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[WARN\] ]] && [[ "$output" =~ Warning\ test ]]
}

@test "read_kvp_field returns text before the first NUL only" {
    source "$PROJECT_ROOT/lib/functions.sh"

    local dirty_pool="$PROJECT_ROOT/test/fixtures/dirty_kvp_pool"

    # Key at record 0: "VMCREATE_MODE\0" followed by stale daemon heap
    # memory (castprefix/ff02:: scraps) — the exact corruption shape the
    # reader must survive.
    run read_kvp_field "$dirty_pool" 0 512
    [ "$status" -eq 0 ]
    [ "$output" = "VMCREATE_MODE" ]
}

@test "read_kvp_field stops at the first NUL in values too" {
    source "$PROJECT_ROOT/lib/functions.sh"

    local dirty_pool="$PROJECT_ROOT/test/fixtures/dirty_kvp_pool"

    # Value at record 0: "customize\0ff02::1%eth0autoconf…"
    run read_kvp_field "$dirty_pool" 512 2048
    [ "$status" -eq 0 ]
    [ "$output" = "customize" ]
}

@test "read_kvp_field reads later records independently" {
    source "$PROJECT_ROOT/lib/functions.sh"

    local dirty_pool="$PROJECT_ROOT/test/fixtures/dirty_kvp_pool"

    # Record 1 key begins at offset 2560
    run read_kvp_field "$dirty_pool" 2560 512
    [ "$status" -eq 0 ]
    [ "$output" = "DiskInfo" ]
}

@test "read_kvp_field stops at the first NUL in record 1's value" {
    source "$PROJECT_ROOT/lib/functions.sh"

    local dirty_pool="$PROJECT_ROOT/test/fixtures/dirty_kvp_pool"

    # Record 1 value: "/dev/sda\0fe80::215:…" (garbage after the NUL)
    run read_kvp_field "$dirty_pool" 3072 2048
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda" ]
}

@test "read_kvp_field returns empty for an all-zero field" {
    source "$PROJECT_ROOT/lib/functions.sh"

    local dirty_pool="$PROJECT_ROOT/test/fixtures/dirty_kvp_pool"

    # Record 3 (offset 7680) is zero padding in the fixture: empty slot
    # detection relies on this being empty, not garbage.
    run read_kvp_field "$dirty_pool" 7680 512
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
