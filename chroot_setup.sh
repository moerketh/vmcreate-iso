#!/bin/bash
set -e

export HOME=/root
echo "vmcreate" > /etc/hostname

cat << EOT > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
EOT

# Initrd compression: default is zstd level 1 — optimized for speed, ~44 MB.
# Level 19 shrinks the initrd a lot for a few seconds of build time while
# keeping zstd's fast kernel-side unpacking: the kernel decompresses the
# initrd single-threaded on EVERY boot (GRUB loads it from the ISO; toram
# only applies to the squashfs), where xz is several times slower for only
# ~2 MB more savings. A conf.d/ drop-in overrides initramfs.conf and
# survives package upgrades; written before any install so every
# update-initramfs pass (kernel postinst, plymouth, the explicit one below)
# uses it.
mkdir -p /etc/initramfs-tools/conf.d
printf 'COMPRESS=zstd\nCOMPRESSLEVEL=19\n' > /etc/initramfs-tools/conf.d/vmcreate-compress

apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends dbus
dbus-uuidgen > /var/lib/dbus/machine-id

# Install initramfs-tools on its own so its conffile exists BEFORE the
# kernel: every later package install (grub, disk tools, tor, openssh,
# plymouth) fires an update-initramfs trigger, and each xz/zstd-19 rebuild
# costs 10-40 s — six rebuilds per build otherwise. update_initramfs=no
# makes those trigger runs (-u) no-ops; only the final explicit rebuild
# below (after restoring =yes) produces the initrd that ships. Writing the
# conffile earlier would not survive: dpkg replaces pre-written conffiles
# on fresh install (it parks them as .dpkg-old).
apt-get install -y --no-install-recommends initramfs-tools
sed -i 's/^update_initramfs=.*/update_initramfs=no/' /etc/initramfs-tools/update-initramfs.conf
grep -q '^update_initramfs=no$' /etc/initramfs-tools/update-initramfs.conf || {
    echo "ERROR: failed to disable update_initramfs" >&2
    exit 1
}

# Install kernel, live tools, and necessary packages
# Resolve the specific kernel version from the linux-virtual meta-package
# (multi-hypervisor: virtio + Hyper-V + VMware drivers) so we can install
# only the image, modules and cloud-tools — skipping the bulky linux-headers,
# linux-tools and linux-modules-extra that the meta-package family pulls in.
# On noble, linux-virtual → linux-image-<ver>-generic in ONE hop, and the
# flavor suffix is whatever apt picked — don't hardcode it.
KVER=$(apt-cache depends linux-image-virtual 2>/dev/null \
    | grep -o 'linux-image-[0-9][0-9.]*-[0-9][0-9]*-[a-z][a-z0-9]*' \
    | head -1 | sed 's/^linux-image-//')
if [ -z "$KVER" ]; then
    echo "ERROR: Could not resolve kernel version from linux-image-virtual" >&2
    exit 1
fi
echo "Resolved kernel version: $KVER"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    linux-image-${KVER} linux-modules-${KVER} linux-cloud-tools-${KVER} \
    casper coreutils systemd-sysv iproute2 zstd xz-utils

# ── Strip kernel modules not needed in VMs ───────────────────────────
# Generic distro kernels ship hundreds of modules for physical hosts.
# The live ISO only needs the virtual drivers (Hyper-V, virtio, VMware),
# storage, local filesystems and basic networking. VMCreate never touches
# zfs or network filesystems on the target (its scripts install the
# target's own kernel userspace from inside the target chroot), and the
# target's GRUB is likewise the target's own — the physical-controller
# and NIC trees below are pure dead weight. The driver whitelist assert
# below runs after this pass.
KMOD_DIR=$(find /lib/modules -maxdepth 1 -mindepth 1 -type d | head -n1)
if [ -d "$KMOD_DIR/kernel" ]; then
    echo "Stripping unnecessary kernel modules from $KMOD_DIR ..."
    # Decompress .ko.zst first: noble ships modules zstd-compressed, and xz
    # (squashfs) / zstd-19 (initrd, see the COMPRESS drop-in above) cannot
    # shrink data that is already compressed. Decompressing also makes the
    # name-based cleanups below see plain .ko files.
    find "$KMOD_DIR" -name '*.ko.zst' -exec unzstd --rm -q {} +
    # Physical GPUs, wireless, media, USB, sound, sensors, staging, ...
    rm -rf "$KMOD_DIR/kernel/drivers/gpu"
    rm -rf "$KMOD_DIR/kernel/drivers/net/wireless"
    rm -rf "$KMOD_DIR/kernel/drivers/bluetooth"
    rm -rf "$KMOD_DIR/kernel/drivers/media"
    rm -rf "$KMOD_DIR/kernel/drivers/usb" # no USB passthrough on the live ISO
    rm -rf "$KMOD_DIR/kernel/drivers/staging"
    rm -rf "$KMOD_DIR/kernel/drivers/infiniband"
    rm -rf "$KMOD_DIR/kernel/drivers/isdn"
    rm -rf "$KMOD_DIR/kernel/drivers/nfc"
    rm -rf "$KMOD_DIR/kernel/drivers/thunderbolt"
    rm -rf "$KMOD_DIR/kernel/drivers/firewire"
    rm -rf "$KMOD_DIR/kernel/drivers/pcmcia"
    rm -rf "$KMOD_DIR/kernel/drivers/platform"
    rm -rf "$KMOD_DIR/kernel/drivers/iio"
    rm -rf "$KMOD_DIR/kernel/drivers/hwmon"
    rm -rf "$KMOD_DIR/kernel/drivers/leds"
    rm -rf "$KMOD_DIR/kernel/drivers/input/joystick"
    rm -rf "$KMOD_DIR/kernel/drivers/input/touchscreen"
    rm -rf "$KMOD_DIR/kernel/drivers/input/gameport"
    rm -rf "$KMOD_DIR/kernel/sound"
    rm -rf "$KMOD_DIR/kernel/net/wireless"
    rm -rf "$KMOD_DIR/kernel/net/bluetooth"
    rm -rf "$KMOD_DIR/kernel/net/mac80211"
    rm -rf "$KMOD_DIR/kernel/net/nfc"
    # Physical NICs (mlx5, bnx2x, i40e, ixgbe, ...): the virtual NICs a VM
    # boots on — hv_netvsc, virtio_net, vmxnet3 — live outside this tree.
    rm -rf "$KMOD_DIR/kernel/drivers/net/ethernet"
    # Physical FC/SAS raid controllers: keep the top-level .ko files a VM
    # needs (sd_mod, sr_mod, virtio_scsi, hv_storvsc, vmw_pvscsi) and the
    # SCSI transport modules; the subdirs are all physical hardware.
    find "$KMOD_DIR/kernel/drivers/scsi" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    rm -rf "$KMOD_DIR/kernel/drivers/target"
    # zfs (kernel/zfs on Ubuntu — NOT fs/zfs) and network filesystems
    # (targets needing them load their own)
    rm -rf "$KMOD_DIR/kernel/zfs" "$KMOD_DIR/kernel/fs/zfs" \
           "$KMOD_DIR/kernel/fs/nfs" "$KMOD_DIR/kernel/fs/nfsd" \
           "$KMOD_DIR/kernel/fs/smb" "$KMOD_DIR/kernel/fs/ceph" "$KMOD_DIR/kernel/fs/dlm" \
           "$KMOD_DIR/kernel/fs/gfs2" "$KMOD_DIR/kernel/fs/ocfs2" \
           "$KMOD_DIR/kernel/fs/9p" \
           "$KMOD_DIR/kernel/net/sunrpc"
    # Protocol stacks and net filtering a deployment VM never uses
    # (netfilter included: VMCreate's eth1 firewall helper is command -v
    # guarded and neither nft nor iptables is installed on the ISO)
    rm -rf "$KMOD_DIR/kernel/net/sched" "$KMOD_DIR/kernel/net/sctp" "$KMOD_DIR/kernel/net/tipc" \
           "$KMOD_DIR/kernel/net/rxrpc" "$KMOD_DIR/kernel/net/can" \
           "$KMOD_DIR/kernel/net/openvswitch" "$KMOD_DIR/kernel/net/mpls" \
           "$KMOD_DIR/kernel/net/6lowpan" "$KMOD_DIR/kernel/net/rds" \
           "$KMOD_DIR/kernel/net/atm" "$KMOD_DIR/kernel/net/dccp" \
           "$KMOD_DIR/kernel/net/ieee802154" "$KMOD_DIR/kernel/net/9p" \
           "$KMOD_DIR/kernel/net/ceph" "$KMOD_DIR/kernel/net/netfilter"
    # Storage/net stacks with no virtual-disk use case
    rm -rf "$KMOD_DIR/kernel/drivers/nvme/target" "$KMOD_DIR/kernel/drivers/md/bcache" \
           "$KMOD_DIR/kernel/drivers/net/wwan" "$KMOD_DIR/kernel/drivers/net/fddi" \
           "$KMOD_DIR/kernel/drivers/net/xen-netback" \
           "$KMOD_DIR/kernel/drivers/vfio" "$KMOD_DIR/kernel/drivers/vhost"
    # KVM host-side virtualization and kernel self-tests. arch/x86/crypto
    # (aesni etc.) stays: dm-crypt on targets uses it for real speedup.
    rm -rf "$KMOD_DIR/kernel/arch/x86/kvm"
    find "$KMOD_DIR" -name 'test_*.ko' -delete
    # Rebuild module dependency map
    depmod -a "$(basename "$KMOD_DIR")"
    echo "Kernel module stripping complete."
fi

# ── Assert the multi-hypervisor driver whitelist survived ───────────
# The transport (hv_sock) and the storage/net drivers VMCreate relies on
# must exist in the image — either as a module file or built into vmlinuz
# (noble ships no /boot/config-*; modules.builtin is the authority for
# built-ins). Fail the build loudly instead of producing an ISO that boots
# but can't be driven or can't see disks.
KVER_SHORT=$(basename "$KMOD_DIR")
driver_ok() {
    local name="$1"
    [ -n "$(find /lib/modules/$KVER_SHORT -name "$name*" 2>/dev/null)" ] && return 0
    grep -q "/$name" /lib/modules/$KVER_SHORT/modules.builtin 2>/dev/null && return 0
    return 1
}
assert_driver() {
    if ! driver_ok "$1"; then
        echo "ERROR: required driver $1 neither built in nor present as a module" >&2
        exit 1
    fi
}
assert_driver "hv_sock.ko"                      # AF_VSOCK transport on Hyper-V (vsock SSH)
assert_driver "hv_storvsc.ko"                   # Hyper-V SCSI (disks on Gen 1/2)
assert_driver "hv_netvsc.ko"                    # Hyper-V synthetic NIC
assert_driver "virtio_blk.ko"                   # KVM disks (built-in on noble)
assert_driver "virtio_scsi.ko"
assert_driver "virtio_net.ko"
assert_driver "vmw_vsock_virtio_transport.ko"   # AF_VSOCK transport on KVM
assert_driver "vmw_pvscsi.ko"                   # VMware paravirtual SCSI (VMware targets)
assert_driver "simpledrm.ko"                    # splash display on the UEFI GOP (drivers/gpu is stripped)
assert_driver "loop.ko"                         # casper mounts the squashfs via loop
assert_driver "overlay.ko"                      # casper rootfs overlay
# Local filesystems the workflows mount (clone/customize) or resize
assert_driver "ext4.ko"                         # most targets' root
assert_driver "xfs.ko"                          # RHEL-style targets
assert_driver "btrfs.ko"                        # e.g. Parrot OS targets (btrfs-progs installed for it)
assert_driver "vfat.ko"                         # ESP (FAT16/32) + the EFI boot image
assert_driver "isofs.ko"                        # the ISO itself (casper)
assert_driver "nls_cp437.ko"                    # vfat short-name codepage
assert_driver "nls_iso8859-1.ko"                # vfat iocharset default (hyphenated on noble)
assert_driver "dm-mod.ko"                       # device-mapper base (built-in on noble)
assert_driver "dm-crypt.ko"                     # LUKS targets (partclone + cryptsetup flows)
assert_driver "md-mod.ko"                       # mdraid base (built-in on noble)
echo "Multi-hypervisor driver whitelist OK."

# Purge linux-firmware — Hyper-V uses synthetic drivers, no firmware blobs needed
apt-get purge -y linux-firmware 2>/dev/null || true

# Configure systemd-networkd for DHCP on Ethernet — the target system's
# package installs run inside this VM, so internet access is still needed.
# (The VMCreate control channel does NOT use this network: it rides vsock.)
mkdir -p /etc/systemd/network
cat << EON > /etc/systemd/network/10-ethernet.network
[Match]
Name=eth*

[Network]
DHCP=ipv4
EON

# Enable systemd-networkd only — nothing here should ever wait for the
# network to be "online".
systemctl enable systemd-networkd 2>/dev/null || true

# NOTE: no bootloader packages in the chroot. The ISO's EFI image is built
# from the BUILD HOST's signed loaders (build.sh), and targets get their
# own GRUB installed from inside their chroot (VMCreate's install_grub.sh)
# — a chroot grub-install would be broken anyway once the module trees are
# stripped. The purge below cleans up if a future dependency ever drags
# them back in (it is a no-op when they are absent).

# Disk tools VMCreate drives remotely (grub2-common was dropped: targets
# get their own GRUB inside their chroot, and update-grub/grub-install
# would be broken here anyway once the module trees are stripped)
apt-get install -y --no-install-recommends partclone gdisk e2fsprogs dosfstools rsync lvm2 efibootmgr util-linux parted psmisc

# Install btrfs-progs for btrfs root filesystem support (e.g. Parrot OS)
apt-get install -y --no-install-recommends btrfs-progs

# Install Tor daemon for distros that route APT through Tor (e.g. Whonix).
# NOT enabled at boot — VMCreate starts it over SSH when tor+ APT sources
# are detected in the target VM's chroot.
apt-get install -y --no-install-recommends tor

# ── SSH over vsock: the VMCreate control channel ─────────────────────
# VMCreate connects without any NIC or IP discovery:
#   host:    ssh -o ProxyCommand="hvc.exe nc -t vsock <vm-guid> 22"
#   guest:   systemd listens on AF_VSOCK and socket-activates sshd -i
# OpenSSH itself has no vsock listener support — systemd provides it.
# hv_sock (the AF_VSOCK transport on Hyper-V) is loaded explicitly via
# modules-load.d; never rely on autoload ordering at early boot.
# There is deliberately NO TCP sshd: openssh-server's postinst enables
# ssh.socket (0.0.0.0:22) on fresh installs by itself, so merely not
# enabling it is not enough — both units are masked, and the assert below
# fails the build if either ever comes back. The only way in is the
# host-private vsock channel.
apt-get install -y --no-install-recommends openssh-server
# Disable password auth — key-only access via KVP-injected pubkey
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl mask ssh.socket ssh.service

# Host keys are generated per boot by the sshd-vsock-keygen oneshot
# (sessions order after it), never baked into the ISO — otherwise every
# published ISO would carry the same private keys.
rm -f /etc/ssh/ssh_host_*

# Load the Hyper-V vsock transport explicitly (the AF_VSOCK socket unit
# depends on it; autoload may fire too late or not at all at early boot).
echo "hv_sock" > /etc/modules-load.d/hv_sock.conf

# Install the systemd units from guest/ (first-class files so CI can
# verify them: systemd-analyze verify + bats assertions in test/).
install -m 644 /tmp/guest/sshd-vsock.socket        /etc/systemd/system/
install -m 644 /tmp/guest/sshd-vsock@.service      /etc/systemd/system/
install -m 644 /tmp/guest/sshd-vsock-keygen.service /etc/systemd/system/
install -m 644 /tmp/guest/inject-ssh-key.service   /etc/systemd/system/
install -m 644 /tmp/guest/vmcreate-sshd.conf       /usr/lib/tmpfiles.d/
systemctl enable sshd-vsock.socket 2>/dev/null || true
systemctl enable inject-ssh-key.service 2>/dev/null || true

# ── Build-time assertions ────────────────────────────────────────────
# TCP sshd must stay dead: openssh-server's postinst enables ssh.socket
# on fresh installs, and a "deliberately not enabled" comment is not a
# guarantee. Fail the build if either unit is anything but masked.
for unit in ssh.socket ssh.service; do
    state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    [ "$state" = "masked" ] || {
        echo "ERROR: TCP sshd unit $unit is '$state' (want masked)" >&2
        exit 1
    }
done
# No baked-in SSH host keys (they are generated per boot at first session).
[ -z "$(ls /etc/ssh/ssh_host_* 2>/dev/null)" ] || {
    echo "ERROR: SSH host keys leaked into the image" >&2
    exit 1
}

# ── Boot splash (Plymouth) ───────────────────────────────────────────
# The VMCreate theme (splash/, graphics by splash/render.py) shows from
# the initramfs until power-off; VMCreate pushes status text over SSH with
# `plymouth display-message` / `plymouth system-update --progress=N`.
# Display: drivers/gpu is stripped, so plymouth renders on the built-in
# simpledrm (UEFI GOP); grub.cfg passes plymouth.use-simpledrm, otherwise
# plymouthd ignores simpledrm until its device timeout. plymouth-label
# provides Image.Text (pango) and pulls in the Ubuntu font.
apt-get install -y --no-install-recommends plymouth plymouth-label
THEME_DIR=/usr/share/plymouth/themes/vmcreate
mkdir -p "$THEME_DIR"
install -m 644 /tmp/splash/vmcreate/* "$THEME_DIR/"
# Debian/Ubuntu select the theme via the default.plymouth alternative (the
# initramfs hook reads it); plymouthd.conf covers the daemon in the rootfs.
update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth \
    "$THEME_DIR/vmcreate.plymouth" 200
update-alternatives --set default.plymouth "$THEME_DIR/vmcreate.plymouth"
mkdir -p /etc/plymouth
printf '[Daemon]\nTheme=vmcreate\nShowDelay=0\n' > /etc/plymouth/plymouthd.conf
# Keep the splash up after boot: nothing may quit plymouth before power-off.
# getty@tty1 would compete with it for the console (and there is no
# password login on this ISO anyway).
systemctl mask plymouth-quit.service plymouth-quit-wait.service getty@tty1.service

# ── Trim before the final initrd build ──────────────────────────────
# udev hardware DB: vendor/model strings and keymaps for physical input
# devices — worthless in a VM (a keyboard works without it), but hwdb.bin
# alone is 11.7 MB and mkinitramfs copies it into the initrd as well, so
# it ships in BOTH images when left here.
rm -rf /usr/lib/udev/hwdb.d /usr/lib/udev/hwdb.bin
# lvm2/btrfs-progs install initramfs hooks that pull the lvm and btrfs
# tools plus their modules into every initrd (~4 MB + xfs/btrfs modules).
# casper boots from a squashfs on the ISO — no lvm/btrfs needed at initrd
# stage. The tools stay in the rootfs for VMCreate's chroot workflows.
rm -f /usr/share/initramfs-tools/hooks/lvm2 /usr/share/initramfs-tools/hooks/btrfs \
      /usr/share/initramfs-tools/scripts/init-bottom/lvm2 \
      /usr/share/initramfs-tools/scripts/local-premount/btrfs
# Fonts: plymouth's theme uses only Ubuntu + Ubuntu Mono (asserted in the
# initrd below). The plymouth hook copies font files into the initrd, so
# this has to happen before the final rebuild to trim BOTH images. NOTE:
# fonts-dejavu-core AND -mono must stay INSTALLED — casper Depends on
# dejavu-core, and purging either cascades casper off the image (apt swaps
# in fonts-liberation and removes casper). Removing the files keeps the
# dependency satisfied with zero glyphs shipped.
rm -rf /usr/share/fonts/truetype/dejavu
rm -f /usr/share/fonts/truetype/ubuntu/UbuntuSans*.ttf
# file(1): casper has a hard Depends: file on noble, so the packages stay
# installed (a purge cascades casper off the image). But nothing in
# casper's initramfs scripts or hooks actually runs file(1), and no hook
# copies it or its DB into the initrd — VMCreate's only file(1) use runs
# inside TARGET chroots. Drop the 8.1 MB database files instead; the
# 31 KB /usr/bin/file binary stays to keep the dependency satisfied.
rm -f /usr/lib/file/magic.mgc /usr/share/misc/magic.mgc /usr/share/file/magic.mgc

# Final initrd: the only generation that actually ships. Restore the trigger
# first — update-initramfs -u honors update_initramfs=no. (-c from the kernel
# postinst ignores it, which is why that first generation is unavoidable.)
sed -i 's/^update_initramfs=.*/update_initramfs=yes/' /etc/initramfs-tools/update-initramfs.conf
update-initramfs -u -k all

# Fail the build unless the splash actually made it into the initrd.
lsinitramfs "/boot/initrd.img-$KVER_SHORT" > /tmp/initrd.list
for f in usr/share/plymouth/themes/vmcreate/vmcreate.plymouth \
         usr/share/plymouth/themes/vmcreate/vmcreate.script \
         usr/share/plymouth/themes/vmcreate/wordmark.png \
         plymouth/script.so \
         plymouth/label-pango.so \
         usr/share/fonts/truetype/ubuntu/Ubuntu; do
    grep -q "$f" /tmp/initrd.list || {
        echo "ERROR: splash: $f missing from initrd" >&2
        exit 1
    }
done
for unit in plymouth-quit.service plymouth-quit-wait.service; do
    state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    [ "$state" = "masked" ] || {
        echo "ERROR: splash: $unit is '$state' (want masked)" >&2
        exit 1
    }
done

# User setup — vmcreate user (matches SshGuestShell's default
# AutomationUser, so VMCreate needs no explicit username). Key-only auth,
# no password; the key is injected at runtime via KVP.
adduser --disabled-password --gecos "" vmcreate
usermod -aG sudo vmcreate
echo "vmcreate ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vmcreate
chmod 0440 /etc/sudoers.d/vmcreate

# Prepare SSH authorized_keys directory (key injected at runtime via KVP)
mkdir -p /home/vmcreate/.ssh
touch /home/vmcreate/.ssh/authorized_keys
chown -R vmcreate:vmcreate /home/vmcreate/.ssh
chmod 700 /home/vmcreate/.ssh
chmod 600 /home/vmcreate/.ssh/authorized_keys

# Create /var/crash to avoid boot error on missing directory
mkdir -p /var/crash

# Boot to console; the system idles at a listening sshd-vsock.socket until
# VMCreate connects and drives the deployment. There is no autorun logic:
# all flow lives host-side (see README.md).
systemctl set-default multi-user.target

# Python is always broken
rm /usr/bin/py3clean
rm /usr/bin/py3compile

# Purge unnecessary packages
apt-get purge -y manpages* libllvm18 libicu74

# Limit locales to English only
apt-get purge -y locales
apt-get install -y --no-install-recommends locales
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# Clean up documentation, manpages, extra locales, and python remnants
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/lib/python* /usr/bin/python*
# Translations and locale machinery (after locale-gen above has run):
# keep only en* message catalogs; /usr/share/i18n is only needed to RUN
# locale-gen; gconv tables serve iconv, which nothing on the image uses.
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' -exec rm -rf {} +
rm -f /usr/share/locale/locale_alias
rm -rf /usr/share/i18n /usr/lib/x86_64-linux-gnu/gconv
# GRUB module trees (~16 MB uncompressed): targets install their OWN GRUB
# from inside the target chroot (VMCreate's install_grub.sh apt/pacman/dnf
# installs there); the live ISO boots via the signed loaders in
# /usr/lib/grub/x86_64-efi-signed — a different package, kept.
# The full purge below supersedes the rm (kept for belt and braces if the
# package set ever changes).
rm -rf /usr/lib/grub/x86_64-efi /usr/lib/grub/i386-pc /usr/share/grub
# EFI loader packages: the ISO image is built from the build host's
# signed loaders, so the chroot's copies are pure duplication (~4.4 MB of
# netboot/CD loader variants alone).
apt-get purge -y grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub2-common
# The purges above remove reverse dependencies silently; make sure the
# packages the ISO literally cannot boot or drive without survived them
# (casper was once cascaded away by a fonts purge).
for pkg in casper plymouth plymouth-label; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || {
        echo "ERROR: $pkg was removed by a later purge" >&2
        exit 1
    }
done

# ── Negative asserts ────────────────────────────────────────────────
# The positive asserts above prove required drivers exist; these prove the
# stripped payload stayed gone. Both of this round's silent no-ops (zfs at
# kernel/zfs rather than fs/zfs; magic.mgc at /usr/lib/file with no arch
# folder) shipped because rm -rf on a wrong path fails silently — assert
# here, after every cleanup has run, so a wrong path can never pass again.
assert_absent() {
    local leaked=""
    for path; do
        # shellcheck disable=SC2086
        ls -d $path >/dev/null 2>&1 && leaked="$leaked $path"
    done
    if [ -n "$leaked" ]; then
        echo "ERROR: stripped payload leaked into the image:$leaked" >&2
        exit 1
    fi
}
assert_absent /lib/modules/*/kernel/zfs /lib/modules/*/kernel/fs/zfs
assert_absent /lib/modules/*/kernel/fs/nfs /lib/modules/*/kernel/fs/smb
assert_absent /lib/modules/*/kernel/fs/9p /lib/modules/*/kernel/net/9p
assert_absent /lib/modules/*/kernel/drivers/net/ethernet
assert_absent /lib/modules/*/kernel/net/netfilter /lib/modules/*/kernel/net/sched
assert_absent /usr/lib/udev/hwdb.bin /usr/lib/udev/hwdb.d
assert_absent /usr/lib/file/magic.mgc /usr/share/misc/magic.mgc /usr/share/file/magic.mgc
assert_absent /usr/lib/grub/x86_64-efi /usr/share/grub
assert_absent /usr/share/fonts/truetype/dejavu
echo "Negative asserts OK — stripped payload stayed gone."

# More cleanup
apt-get autoremove -y
apt-get clean -y
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/* /var/cache/debconf/*

# autoremove can cascade packages away just like the purges above (it once
# took sudo with a casper dependency chain); re-check the boot-critical set
# AFTER it, right before the image is sealed.
for pkg in casper plymouth plymouth-label; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || {
        echo "ERROR: $pkg was removed by a later purge or autoremove" >&2
        exit 1
    }
done

rm -f /var/lib/dbus/machine-id
truncate -s 0 /etc/machine-id

exit
