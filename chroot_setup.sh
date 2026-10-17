#!/bin/bash
set -e

export HOME=/root
echo "vmcreate" > /etc/hostname

cat << EOT > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
EOT

apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends dbus
dbus-uuidgen > /var/lib/dbus/machine-id

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
    casper coreutils systemd-sysv iproute2 zstd

# ── Strip kernel modules not needed in VMs ───────────────────────────
# Generic distro kernels ship hundreds of modules for physical hosts.
# The live ISO only needs the virtual drivers (Hyper-V, virtio), storage,
# filesystems, and basic networking. Removing the rest saves 30-50 MB in
# the squashfs. The driver whitelist assert below runs after this pass.
KMOD_DIR=$(find /lib/modules -maxdepth 1 -mindepth 1 -type d | head -n1)
if [ -d "$KMOD_DIR/kernel" ]; then
    echo "Stripping unnecessary kernel modules from $KMOD_DIR ..."
    # Remove large driver subtrees that are irrelevant in VMs
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

# Bootloaders for UEFI/Secure Boot (Gen 2 only — no BIOS support)
apt-get install -y --no-install-recommends grub-efi-amd64-signed shim-signed

# Disk tools VMCreate drives remotely
apt-get install -y --no-install-recommends partclone gdisk e2fsprogs dosfstools rsync lvm2 efibootmgr grub2-common util-linux parted psmisc

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
# There is deliberately NO TCP sshd: the only way in is the host-private
# vsock channel. Auth bootstrap: the host writes the SSH public key via
# KVP right after VM start; inject_ssh_key.sh (autorun/) installs it
# before sessions are accepted. Password auth is disabled.
apt-get install -y --no-install-recommends openssh-server
# Disable password auth — key-only access via KVP-injected pubkey
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

# Explicitly load the Hyper-V vsock transport at boot (the AF_VSOCK socket
# unit below depends on it; autoload may fire too late or not at all).
echo "hv_sock" > /etc/modules-load.d/hv_sock.conf

# Install the systemd units from guest/ (first-class files so CI can
# verify them: systemd-analyze verify + bats assertions in test/).
install -m 644 /tmp/guest/sshd-vsock.socket        /etc/systemd/system/
install -m 644 /tmp/guest/sshd-vsock@.service      /etc/systemd/system/
install -m 644 /tmp/guest/inject-ssh-key.service   /etc/systemd/system/
install -m 644 /tmp/guest/vmcreate-sshd.conf       /usr/lib/tmpfiles.d/
systemctl enable sshd-vsock.socket 2>/dev/null || true
systemctl enable inject-ssh-key.service 2>/dev/null || true

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
#rm -rf /usr/share/locale/!(en|en_US|en_US.UTF-8)

# More cleanup
apt-get autoremove -y
apt-get clean -y
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/* /var/cache/debconf/*

rm -f /var/lib/dbus/machine-id
truncate -s 0 /etc/machine-id

exit
