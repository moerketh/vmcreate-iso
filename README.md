# vmcreate-iso

Boot medium for [VMCreate](https://github.com/moerketh/VMCreate) deployments.

## What it is

A minimal, **logic-free** live ISO. It boots the VM and offers exactly two
things:

- **sshd over Hyper-V vsock** (socket-activated, `sshd -i` per connection,
  port 22) — the host connects with
  `ssh -o ProxyCommand="hvc.exe nc -t vsock <vm-guid> 22"`; no NIC, no IP
  discovery, no DHCP dependency for the control channel
- **baked disk tools** (partclone, lvm2, btrfs-progs, gdisk, rsync, …) that
  VMCreate drives remotely

All deployment logic lives in VMCreate and is pushed per deploy. The only
guest-side bootstrap is the SSH **public key**, delivered via host→guest KVP
(`VMCREATE_SSH_PUBKEY`) and installed by `autorun/inject_ssh_key.sh` using a
first-NUL reader (see `lib/functions.sh` — stale heap bytes behind the
terminator are a documented hv_kvp_daemon behavior).

Kernel: `linux-virtual` (virtio + Hyper-V + VMware drivers — boots on
Hyper-V Gen 1/2 today, QEMU/KVM untested). Secure Boot: Microsoft-signed
shim/grub chain, UEFI-only.

## Build

From a native Linux filesystem (WSL: copy out of /mnt/c first):

```bash
sudo apt-get install -y debootstrap squashfs-tools xorriso grub-efi-amd64-bin \
    grub-efi-amd64-signed shim-signed mtools dosfstools
./build.sh
```

Releases are tagged `v*`; CI builds, tests (bats) and attaches the ISO +
sha256 to the GitHub release. VMCreate downloads whatever release is
`latest` and replaces its cached copy when the version differs.

## Layout

```
build.sh          debootstrap → chroot → squashfs → ISO
chroot_setup.sh   runs inside the chroot: kernel, sshd, vsock socket units
autorun/          inject_ssh_key.sh — the only boot-time logic
lib/functions.sh  log + read_kvp_field (first-NUL KVP reader)
test/             bats tests; fixtures include a dirty (garbage-after-NUL) pool
```
