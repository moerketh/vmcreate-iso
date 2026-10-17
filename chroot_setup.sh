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

# ── Strip kernel modules not needed for Hyper-V ──────────────────────
# linux-azure ships hundreds of modules for bare-metal Azure hosts.
# The live ISO only needs Hyper-V synthetic drivers, storage, filesystems,
# and basic networking. Removing the rest saves 30-50 MB in the squashfs.
KMOD_DIR=$(find /lib/modules -maxdepth 1 -mindepth 1 -type d | head -n1)
if [ -d "$KMOD_DIR/kernel" ]; then
    echo "Stripping unnecessary kernel modules from $KMOD_DIR ..."
    # Remove large driver subtrees that are irrelevant inside Hyper-V
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

# ── Assert the multi-hypervisor module whitelist survived ────────────
# The transport (hv_sock) and the storage drivers VMCreate relies on when
# driving a clone must exist in the image — as a module file or built into
# the kernel. Fail the build loudly instead of producing an ISO that boots
# but can't be driven or can't see disks.
KVER_SHORT=$(basename "$KMOD_DIR")
KERNEL_CONFIG="/boot/config-${KVER_SHORT}"
assert_driver() {
    local cfg="$1" ko="$2"
    if [ -f "$KERNEL_CONFIG" ] && grep -q "^${cfg}=y" "$KERNEL_CONFIG"; then
        return 0
    fi
    if [ -n "$(find /lib/modules/$KVER_SHORT -name "$ko" 2>/dev/null)" ]; then
        return 0
    fi
    echo "ERROR: required driver $cfg ($ko) not built in and not a module" >&2
    exit 1
}
assert_driver CONFIG_HYPERV_VSOCKETS "hv_sock.ko*"       # AF_VSOCK transport on Hyper-V (vsock SSH)
assert_driver CONFIG_HYPERV_STORAGE "storvsc.ko*"        # Hyper-V SCSI (disks on Gen 1/2)
assert_driver CONFIG_HYPERV_NET     "hv_netvsc.ko*"      # Hyper-V synthetic NIC
assert_driver CONFIG_VIRTIO_BLK     "virtio_blk.ko*"     # KVM disks
assert_driver CONFIG_SCSI_VIRTIO    "virtio_scsi.ko*"
assert_driver CONFIG_VIRTIO_NET     "virtio_net.ko*"
assert_driver CONFIG_VIRTIO_VSOCKETS "vsock_virtio.ko*"  # AF_VSOCK transport on KVM
echo "Multi-hypervisor driver whitelist OK."

# Purge linux-firmware — Hyper-V uses synthetic drivers, no firmware blobs needed
apt-get purge -y linux-firmware 2>/dev/null || true

# Configure systemd-networkd for DHCP on Ethernet
mkdir -p /etc/systemd/network
cat << EON > /etc/systemd/network/10-ethernet.network
[Match]
Name=eth*

[Network]
DHCP=ipv4
EON

# Enable systemd-networkd
systemctl enable systemd-networkd 2>/dev/null || true
systemctl enable systemd-networkd-wait-online 2>/dev/null || true

# Bootloaders for UEFI/Secure Boot (Gen 2 only — no BIOS support)
apt-get install -y --no-install-recommends grub-efi-amd64-signed shim-signed

# Packages for autorun script (disk tools)
apt-get install -y --no-install-recommends partclone gdisk e2fsprogs dosfstools rsync lvm2 efibootmgr grub2-common util-linux parted psmisc

# Install btrfs-progs for btrfs root filesystem support (e.g. Parrot OS)
apt-get install -y --no-install-recommends btrfs-progs

# Install Tor daemon for distros that route APT through Tor (e.g. Whonix).
# NOT enabled at boot — started on-demand by autorun when tor+ APT sources
# are detected in the target VM's chroot.
apt-get install -y --no-install-recommends tor

# ── SSH: TCP (debug/fallback) + vsock (VMCreate control channel) ────
# VMCreate connects without any NIC or IP discovery:
#   host:    ssh -o ProxyCommand="hvc.exe nc -t vsock <vm-guid> 22"
#   guest:   systemd listens on AF_VSOCK and socket-activates sshd -i
# OpenSSH itself has no vsock listener support — systemd provides it.
# hv_sock (the AF_VSOCK transport on Hyper-V) is loaded explicitly via
# modules-load.d; never rely on autoload ordering at early boot.
# Auth bootstrap: the host writes the SSH public key via KVP right after
# VM start; inject_ssh_key.sh (autorun/) installs it before we accept
# connections. Password auth is disabled.
apt-get install -y --no-install-recommends openssh-server
# Disable password auth — key-only access via KVP-injected pubkey
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
# TCP sshd stays enabled as a debug/fallback path on any NIC the VM has
systemctl enable ssh 2>/dev/null || true

# Explicitly load the Hyper-V vsock transport at boot (the AF_VSOCK socket
# unit below depends on it; autoload may fire too late or not at all).
echo "hv_sock" > /etc/modules-load.d/hv_sock.conf

# vsock listener: systemd accepts on AF_VSOCK port 22, spawns sshd -i per
# connection (inetd style). ListenStream=vsock syntax verified for systemd
# 255 (noble); see Phase 0 V4 in the vsock plan before changing it.
cat << 'VSOCKSOCKET' > /etc/systemd/system/sshd-vsock.socket
[Unit]
Description=VMCreate sshd over Hyper-V vsock
ConditionPathExists=/dev/vmbus/hv_socket

[Socket]
ListenStream=vsock::22
Accept=yes

[Install]
WantedBy=multi-user.target
VSOCKSOCKET

cat << 'VSOCKSERVICE' > /etc/systemd/system/sshd-vsock@.service
[Unit]
Description=sshd session over vsock (%i)

[Service]
ExecStart=-/usr/sbin/sshd -i
StandardInput=socket
StandardOutput=socket
StandardError=socket
VSOCKSERVICE

systemctl enable sshd-vsock.socket 2>/dev/null || true

# User setup — ubuntu user for SSH (key-only auth, no password)
adduser --disabled-password --gecos "" ubuntu
usermod -aG sudo ubuntu
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 0440 /etc/sudoers.d/ubuntu

# Prepare SSH authorized_keys directory (key injected at runtime via KVP)
mkdir -p /home/ubuntu/.ssh
touch /home/ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh

# Systemd service to run key injection early in boot
cat << 'KVPUNIT' > /etc/systemd/system/inject-ssh-key.service
[Unit]
Description=Inject SSH public key from Hyper-V KVP
After=hv-kvp-daemon.service
Before=ssh.service sshd-vsock.socket
Wants=hv-kvp-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/autorun/inject_ssh_key.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
KVPUNIT
systemctl enable inject-ssh-key.service 2>/dev/null || true

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
