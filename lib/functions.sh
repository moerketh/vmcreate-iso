#!/bin/bash
# vmcreate-iso — minimal guest library.
# The ISO is logic-free by design: VMCreate drives every step over SSH
# (vsock). This library contains only what runs guest-side at boot.

# Sourcing guard to prevent multiple inclusions
[[ -n "${FUNCTIONS_SH_LOADED:-}" ]] && return
FUNCTIONS_SH_LOADED=1

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO|WARN|ERROR)
            echo "[$timestamp] [$level] $message" | tee -a /var/log/vmcreate-iso.log
            ;;
        *)
            echo "[$timestamp] [INFO] $message" | tee -a /var/log/vmcreate-iso.log
            ;;
    esac
}

# Print the NUL-terminated string in [offset, offset+size) of a pool file.
# hv_kvp_daemon never zeroes the bytes behind a record's terminating NUL
# (its buffer is malloc'd, not calloc'd), so readers must stop at the first
# NUL instead of stripping all of them — otherwise stale heap memory gets
# glued onto real values.  sed -n 1p (not head) keeps the producer alive:
# head exits at the first line and dd dies with SIGPIPE, which would fail
# the pipeline under `set -eo pipefail`.
read_kvp_field() {
    dd status=none if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | tr '\0' '\n' | sed -n 1p
}
