#!/usr/bin/env bats

# Assertions on the guest systemd units in guest/. These exist so the three
# boot-breaking bugs caught in review can never come back silently:
#   1. a ConditionPathExists= on a device node that never exists
#   2. an ordering cycle between inject-ssh-key.service and the socket
#   3. a missing /run/sshd (sshd -i refuses to start without it)
# CI additionally runs `systemd-analyze verify` (see .github/workflows).

load 'test_helper'

@test "socket conditions on /dev/vsock, not the nonexistent /dev/vmbus path" {
    grep -q '^ConditionPathExists=/dev/vsock$' "$PROJECT_ROOT/guest/sshd-vsock.socket"
    ! grep -q '/dev/vmbus' "$PROJECT_ROOT/guest/sshd-vsock.socket"
}

@test "socket listens on AF_VSOCK port 22 and is accepted per connection" {
    grep -q '^ListenStream=vsock::22$' "$PROJECT_ROOT/guest/sshd-vsock.socket"
    grep -q '^Accept=yes$' "$PROJECT_ROOT/guest/sshd-vsock.socket"
}

@test "socket is wanted by sockets.target (not multi-user)" {
    grep -q '^WantedBy=sockets.target$' "$PROJECT_ROOT/guest/sshd-vsock.socket"
}

@test "no unit orders a plain service before the socket (ordering cycle)" {
    ! grep -rq 'Before=.*sshd-vsock' "$PROJECT_ROOT/guest/"
}

@test "session service waits for key injection (After=, the safe direction)" {
    grep -q '^After=inject-ssh-key.service$' "$PROJECT_ROOT/guest/sshd-vsock@.service"
}

@test "session service runs sshd -i on the socket" {
    grep -q '^ExecStart=-/usr/sbin/sshd -i$' "$PROJECT_ROOT/guest/sshd-vsock@.service"
    grep -q '^StandardInput=socket$' "$PROJECT_ROOT/guest/sshd-vsock@.service"
}

@test "tmpfiles entry creates /run/sshd for sshd -i" {
    grep -q '^d /run/sshd 0755 root root -$' "$PROJECT_ROOT/guest/vmcreate-sshd.conf"
}

@test "injection service has no Before= on any socket or ssh unit" {
    ! grep -q 'Before=' "$PROJECT_ROOT/guest/inject-ssh-key.service"
}
