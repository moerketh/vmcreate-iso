#!/bin/bash
set -e

# Build the VMCreate deployment ISO: a logic-free live Ubuntu that boots
# to a vsock-activated sshd and waits for VMCreate to drive it.
# UEFI + Secure Boot (Microsoft UEFI CA) — Hyper-V Gen 2.

WORK_DIR=$(pwd)
UBUNTU_VERSION="noble"  # Ubuntu 24.04 LTS
DNS_PATCHED=false

# ── Cleanup trap ─────────────────────────────────────────────────────
# If the build is interrupted (Ctrl-C, error with set -e, etc.), make sure
# we unmount the chroot bind mounts so WSL doesn't end up with dangling
# mounts that can break on restart.
cleanup_build() {
    echo "Cleaning up..."
    sudo umount -l "$WORK_DIR/chroot/dev/shm" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev/pts" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev/hugepages" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev/mqueue" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/run" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/proc" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/sys" 2>/dev/null || true
    # Restore resolv.conf if we patched it
    if [ "$DNS_PATCHED" = true ] && [ -e /etc/resolv.conf.bak.build ]; then
        sudo mv /etc/resolv.conf.bak.build /etc/resolv.conf
        echo "Restored original /etc/resolv.conf"
    fi
}
trap cleanup_build EXIT

# Read version from VERSION file
if [ -f "$WORK_DIR/VERSION" ]; then
    BUILD_VERSION=$(cat "$WORK_DIR/VERSION" | tr -d '[:space:]')
else
    BUILD_VERSION="0.0.0-dev"
fi
# The version is interpolated into file names, a sed replacement and CI
# outputs — reject anything but a semver-ish token up front instead of
# letting a stray '&', '|' or '\' corrupt the build far downstream.
if ! echo "$BUILD_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}(-[A-Za-z0-9.]+)?$'; then
    echo "ERROR: VERSION contains invalid characters: '$BUILD_VERSION'" >&2
    exit 1
fi
echo "Building vmcreate-iso version $BUILD_VERSION"

ISO_NAME="vmcreate-${BUILD_VERSION}.iso"

# Abort if running on an NTFS/Windows filesystem (e.g. /mnt/c in WSL).
# debootstrap needs Unix symlinks, device nodes, and proper permissions which NTFS cannot provide.
fs_type=$(df --output=fstype "$WORK_DIR" 2>/dev/null | tail -1)
if [[ "$fs_type" == "9p" || "$fs_type" == "drvfs" || "$WORK_DIR" == /mnt/[a-z]/* ]]; then
    echo "ERROR: This script must be run from a native Linux filesystem, not an NTFS mount ($WORK_DIR)." >&2
    echo "       debootstrap will fail on NTFS because it cannot create Unix symlinks and device nodes." >&2
    echo "       Copy the repo to a native path first:  cp -r . ~/vmcreate-iso && cd ~/vmcreate-iso" >&2
    exit 1
fi

# Cleanup to prevent busy device issues from previous runs
if [ -d "$WORK_DIR/chroot" ]; then
    echo "Cleaning up existing chroot directory..."
    # Lazy unmount all possible mounts (removed fuser to avoid killing system processes)
    sudo umount -l "$WORK_DIR/chroot/dev/shm" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev/pts" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev/hugepages" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev/mqueue" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/dev" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/run" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/proc" 2>/dev/null || true
    sudo umount -l "$WORK_DIR/chroot/sys" 2>/dev/null || true
    # Check for remaining mounts
    if mount | grep -q "$WORK_DIR/chroot"; then
        echo "Warning: Some mounts still active. Run 'mount | grep chroot' and unmount manually before re-running."
        exit 1
    fi
    sudo rm -rf "$WORK_DIR/chroot"
fi

# ── Ensure DNS works (WSL often has a broken resolv.conf) ────────────
if ! getent hosts archive.ubuntu.com > /dev/null 2>&1; then
    echo "DNS resolution failed — attempting temporary fix..."
    # Preserve the original resolv.conf (often a WSL-managed symlink) so we
    # can restore it later and avoid permanently breaking WSL networking.
    if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
        sudo cp -a /etc/resolv.conf /etc/resolv.conf.bak.build
    fi
    sudo rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf > /dev/null
    DNS_PATCHED=true
    if ! getent hosts archive.ubuntu.com > /dev/null 2>&1; then
        echo "ERROR: DNS still broken after fix. Check your network connection." >&2
        # Restore original before exiting
        if [ -e /etc/resolv.conf.bak.build ]; then
            sudo mv /etc/resolv.conf.bak.build /etc/resolv.conf
        fi
        exit 1
    fi
    echo "DNS resolution restored (will revert resolv.conf at end of build)."
fi

# Install dependencies
sudo apt-get update
sudo apt-get install -y debootstrap squashfs-tools xorriso grub-efi-amd64-bin grub-efi-amd64-signed shim-signed mtools dosfstools

# The EFI image is built from the BUILD HOST's signed loaders, so the host
# distro leaks into the ISO: Ubuntu's signed GRUB embeds /EFI/ubuntu (the
# load-bearing graft below), but Debian's looks for /EFI/debian — such a
# host would build fine and then drop to a grub> prompt at boot. Fail the
# build here instead of at boot.
sudo grep -aq '/EFI/ubuntu' /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed || {
    echo "ERROR: build host's signed GRUB does not search /EFI/ubuntu — wrong distro?" >&2
    exit 1
}

# Bootstrap minimal Ubuntu — try multiple mirrors in case one is unreachable.
# https: apt verifies packages via GPG either way, but TLS hides the (host,
# package list) metadata from passive observers. --keyring makes signature
# verification explicit: debootstrap only warns (and proceeds unsigned)
# when the suite keyring is missing on an unusual host — fail closed.
UBUNTU_MIRRORS=(
    "https://archive.ubuntu.com/ubuntu/"
    "https://us.archive.ubuntu.com/ubuntu/"
    "https://eu.archive.ubuntu.com/ubuntu/"
    "https://de.archive.ubuntu.com/ubuntu/"
    "https://nl.archive.ubuntu.com/ubuntu/"
    "https://se.archive.ubuntu.com/ubuntu/"
    "https://mirrors.kernel.org/ubuntu/"
)

DEBOOTSTRAP_OK=false
for mirror in "${UBUNTU_MIRRORS[@]}"; do
    echo "Trying debootstrap with mirror: $mirror"
    if sudo debootstrap --arch=amd64 --variant=minbase \
        --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
        "$UBUNTU_VERSION" chroot "$mirror"; then
        DEBOOTSTRAP_MIRROR="$mirror"
        DEBOOTSTRAP_OK=true
        break
    fi
    echo "Mirror $mirror failed, trying next..."
    sudo rm -rf chroot
done

if [ "$DEBOOTSTRAP_OK" != true ]; then
    echo "ERROR: All Ubuntu mirrors failed. Check your network connection." >&2
    exit 1
fi
echo "debootstrap succeeded with mirror: $DEBOOTSTRAP_MIRROR"

# Copy boot scripts and lib to chroot
source_dir="./autorun"
dest_dir="chroot/opt/autorun"
lib_dir="chroot/opt/lib"
sudo mkdir -p $dest_dir $lib_dir

# Shared library (inject_ssh_key.sh sources /opt/lib/functions.sh)
sudo cp ./lib/functions.sh "$lib_dir/functions.sh"
sudo chmod +x "$lib_dir/functions.sh"

# Embed build version inside the chroot for runtime logging
echo "$BUILD_VERSION" | sudo tee "chroot/etc/vmcreate-iso-version" > /dev/null

for file in "$source_dir"/*.sh; do
  if [ -f "$file" ]; then
    filename=$(basename "$file")
    sudo cp "$file" "$dest_dir/$filename"
    sudo chmod +x "$dest_dir/$filename"
  else
    echo "No .sh files found in $source_dir, skipping."
  fi
done

# Mount binds
sudo mount --bind /dev chroot/dev
sudo mount --bind /run chroot/run
sudo chroot chroot mount -t proc none /proc
sudo chroot chroot mount -t sysfs none /sys
sudo chroot chroot mount -t devpts none /dev/pts

# Ensure DNS works inside the chroot (resolv.conf is often a dangling
# symlink to systemd-resolved which isn't running in the chroot)
sudo rm -f chroot/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee chroot/etc/resolv.conf > /dev/null

# Setup chroot: copy the chroot script, guest systemd units (installed by
# chroot_setup.sh from /tmp/guest/), then run the setup inside the chroot.
sudo cp ./chroot_setup.sh chroot/tmp/chroot_setup.sh
sudo mkdir -p chroot/tmp/guest
sudo cp ./guest/* chroot/tmp/guest/
# Plymouth theme (installed by chroot_setup.sh from /tmp/splash/); the
# script gets the build version stamped into its footer.
sudo mkdir -p chroot/tmp/splash/vmcreate
sudo cp ./splash/vmcreate/* chroot/tmp/splash/vmcreate/
sudo sed -i "s|@VMCREATE_ISO_VERSION@|${BUILD_VERSION}|" chroot/tmp/splash/vmcreate/vmcreate.script
# initramfs hook (installed by chroot_setup.sh from /tmp/initramfs/) that
# trims xfs/btrfs/iscsi modules from the initrd — kept as a first-class
# file like guest/ and splash/ so it is linted and visible in review.
sudo mkdir -p chroot/tmp/initramfs
sudo cp ./initramfs/* chroot/tmp/initramfs/
sudo chroot chroot /bin/bash /tmp/chroot_setup.sh

# Unmount
sudo chroot chroot umount /proc || true
sudo chroot chroot umount /sys || true
sudo chroot chroot umount /dev/pts || true
sudo umount -l chroot/dev/shm 2>/dev/null || true
sudo umount -l chroot/dev/pts 2>/dev/null || true
sudo umount -l chroot/dev/hugepages 2>/dev/null || true
sudo umount -l chroot/dev/mqueue 2>/dev/null || true
sudo umount chroot/dev
sudo umount chroot/run

# Prepare image directory
mkdir -p image/{casper,isolinux,boot/grub}
touch image/ubuntu  # Create marker file for GRUB search command

# Copy kernel and initrd
KERNEL_VERSION=$(ls chroot/boot/vmlinuz-* | head -n1 | cut -d- -f2-)
sudo cp "chroot/boot/vmlinuz-${KERNEL_VERSION}" image/casper/vmlinuz
sudo cp "chroot/boot/initrd.img-${KERNEL_VERSION}" image/casper/initrd

# Measure as we build: sizes here are what the ISO download actually pays,
# and toram pays the squashfs+initrd again at every boot. --apparent-size:
# truncated/sparse files (efiboot.img) would otherwise report near zero.
measure() { sudo du -h --apparent-size "$1" | cut -f1; }
printf 'SIZE kernel  %8s  image/casper/vmlinuz\n' "$(measure image/casper/vmlinuz)"
printf 'SIZE initrd  %8s  image/casper/initrd\n' "$(measure image/casper/initrd)"

# Create manifest
sudo chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' > image/casper/filesystem.manifest
sudo cp image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop
sudo sed -i '/ubiquity/d' image/casper/filesystem.manifest-desktop
sudo sed -i '/casper/d' image/casper/filesystem.manifest-desktop

# Compress filesystem
sudo mksquashfs chroot image/casper/filesystem.squashfs -comp xz -b 1M -Xdict-size 100% -Xbcj x86 -noappend -no-duplicates -no-recovery -wildcards -e "var/cache/apt/archives/*" "root/*" "root/.*" "tmp/*" "tmp/.*" "swapfile" "boot/*"

# Verify squashfs integrity — catches corrupt xz blocks before they become
# unbootable ISOs (block 0x301884 failure in PwnCloudOS_20260310112945).
echo "Verifying squashfs integrity..."
if sudo unsquashfs -s image/casper/filesystem.squashfs > /dev/null 2>&1 && \
   sudo unsquashfs -l image/casper/filesystem.squashfs > /dev/null 2>&1; then
    echo "Squashfs verification PASSED"
else
    echo "ERROR: Squashfs verification FAILED — the image is corrupt. Aborting." >&2
    exit 1
fi
printf 'SIZE squashfs %7s  image/casper/filesystem.squashfs\n' "$(measure image/casper/filesystem.squashfs)"

# Print filesystem size
printf $(sudo du -sx --block-size=1 chroot | cut -f1) > image/casper/filesystem.size

# Access image directory
cd image

# Copy custom grub config (goes into the EFI boot image and the ISO
# filesystem below)
sudo cp ../grub.cfg isolinux/grub.cfg

# Ubuntu's signed grubx64.efi has an embedded early config that runs
# `search --file /EFI/ubuntu/grub.cfg` on its *boot device* — the El Torito
# virtual CD, i.e. this ISO filesystem — and drops to the GRUB prompt if it
# finds nothing. The copy inside the appended FAT partition is never read,
# so this graft is load-bearing (verified: removing it lands on `grub>`).
mkdir -p EFI/ubuntu
sudo cp ../grub.cfg EFI/ubuntu/grub.cfg

# Create EFI boot image — sized to fit: the fixed 10 MB image held ~4.5 MB
# of loaders. Only its El Torito boot entry matters (see the EFI/ubuntu
# graft above), so every MB here is a MB in the ISO download. The 256 KiB
# headroom absorbs upstream loader size growth.
EFI_SRC_FILES=(
    /usr/lib/shim/shimx64.efi.signed
    /usr/lib/shim/mmx64.efi
    /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
    isolinux/grub.cfg
)
# FAT16 needs >=4085 clusters, so force 512-byte clusters (-s 1) and keep a
# 3 MiB floor (6144 clusters) — that is why the old fixed image was 10 MB.
# -L: shim's loader is an update-alternatives symlink; measure the real file.
EFI_IMG_BYTES=$(( $(du -bcL "${EFI_SRC_FILES[@]}" | tail -1 | cut -f1) + 256*1024 ))
if [ "$EFI_IMG_BYTES" -lt 3145728 ]; then EFI_IMG_BYTES=3145728; fi
EFI_IMG_BYTES=$(( (EFI_IMG_BYTES + 511) / 512 * 512 ))
truncate -s "$EFI_IMG_BYTES" ${WORK_DIR}/image/isolinux/efiboot.img
mkfs.vfat -F 16 -s 1 -n "EFI Boot" ${WORK_DIR}/image/isolinux/efiboot.img >/dev/null
printf 'SIZE efiboot %8s  isolinux/efiboot.img\n' "$(measure "${WORK_DIR}/image/isolinux/efiboot.img")"
mloop=$(sudo losetup --show -f ${WORK_DIR}/image/isolinux/efiboot.img)
sudo mkdir -p /mnt/efi
sudo mount "${mloop}" /mnt/efi
sudo mkdir -p /mnt/efi/EFI/boot
sudo mkdir -p /mnt/efi/EFI/ubuntu
sudo cp /usr/lib/shim/shimx64.efi.signed /mnt/efi/EFI/boot/bootx64.efi
sudo cp /usr/lib/shim/mmx64.efi /mnt/efi/EFI/boot/mmx64.efi
sudo cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /mnt/efi/EFI/boot/grubx64.efi
# Not read by this ISO's boot path (GRUB finds /EFI/ubuntu/grub.cfg in
# the ISO filesystem, grafted above) — kept only as a fallback config if
# the partition is ever extracted and booted standalone (e.g. dd'd onto
# a USB stick's ESP). Costs 805 bytes.
sudo cp ./isolinux/grub.cfg /mnt/efi/EFI/ubuntu/grub.cfg
sudo umount /mnt/efi
sudo losetup -d "${mloop}"
sudo rm -rf /mnt/efi

# Generate md5sum.txt
# Exclude at the find level (not by grepping md5sum output, whose lines
# start with the hash): the isolinux/ staging dir is not part of the ISO
# filesystem and the receipt must not hash itself.
sudo rm -f md5sum.txt
sudo /bin/bash -c "(find . -type f ! -path './isolinux/*' ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt)"

# Create ISO (UEFI-only, no BIOS El Torito): a single El Torito boot entry
# points straight at the appended GPT partition that carries efiboot.img,
# so the image exists exactly once in the ISO.
sudo xorriso \
  -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -J -J -joliet-long \
  -volid "VMCreate ISO" \
  -output "../${ISO_NAME}" \
  -no-emul-boot \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b isolinux/efiboot.img \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -e '--interval:appended_partition_2:::' \
  -exclude isolinux \
  "."

cd ..
echo "ISO created at ${WORK_DIR}/${ISO_NAME}"
printf 'SIZE iso     %8s  %s\n' "$(du -h "${ISO_NAME}" | cut -f1)" "$ISO_NAME"

# cleanup_build runs automatically via the EXIT trap
