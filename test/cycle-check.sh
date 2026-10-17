#!/bin/bash
# Local replica of the CI cycle check (run inside WSL).
set -u
cd /tmp && rm -rf kcheck && mkdir kcheck
cp /mnt/c/repos/moerketh/vmcreate-iso/guest/* kcheck/
cd kcheck
printf '[Unit]\nWants=basic.target sockets.target sshd-vsock.socket inject-ssh-key.service sshd-vsock-keygen.service\n' > cycle-check.target
out=$(systemd-analyze verify cycle-check.target *.socket *.service 2>&1 | grep -v marked || true)
echo "verify output: ${out:-<clean>}"
if echo "$out" | grep -qi 'ordering cycle'; then
    echo CYCLE-FAIL
    exit 1
fi
echo CYCLE-CHECK-PASS
