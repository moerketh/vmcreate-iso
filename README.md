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

Kernel: `linux-virtual` (virtio + Hyper-V + VMware drivers — boots on Hyper-V
Gen 2 and under QEMU/KVM with OVMF + Secure Boot). UEFI + Secure Boot
(Microsoft-signed shim/grub chain); no BIOS boot. SSH user: `vmcreate`
(key-only, passwordless sudo), matching VMCreate's default.

## Splash screen

![splash](splash/preview.png)

A Plymouth theme shows from the initramfs until power-off (the GRUB menu is
hidden; hold Esc/Shift for it, including a verbose no-splash entry; Esc on
the splash shows the console log). The ISO only ships the theme — VMCreate
drives the text over SSH with stock plymouth commands:

```bash
sudo plymouth display-message --text="Cloning disk 1 of 2"
sudo plymouth system-update --progress=42   # 1..100: determinate bar
sudo plymouth system-update --progress=0    # back to the indeterminate sweep
```

The graphics are generated, not drawn: `python3 splash/render.py --preview`
(Pillow) rewrites `splash/vmcreate/*.png` and the preview above. Plymouth
renders on the built-in simpledrm (`drivers/gpu` is stripped), hence
`plymouth.use-simpledrm` on the kernel command line.

## Build

From a native Linux filesystem (WSL: copy out of /mnt/c first), on an
**Ubuntu host**: the EFI boot image embeds the host's signed grub/shim, and
Ubuntu's signed GRUB searches for `/EFI/ubuntu/grub.cfg` — a Debian host
builds fine but lands on a `grub>` prompt at boot (build.sh fails fast on
this). CI pins `ubuntu-24.04` for the same reason.

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
guest/            systemd units + tmpfiles, first-class so CI verifies them
initramfs/        initramfs hook trimming xfs/btrfs/iscsi modules from the
                  initrd (they stay in the rootfs for target deployments)
splash/           Plymouth theme (vmcreate/) + render.py that generates it
autorun/          inject_ssh_key.sh — the only boot-time logic
lib/functions.sh  log + read_kvp_field (first-NUL KVP reader)
test/             bats: reader tests, inject_ssh_key tests (real script,
                  test hooks), guest unit and splash assertions; CI also runs
                  systemd-analyze verify on guest/
```
