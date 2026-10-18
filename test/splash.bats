#!/usr/bin/env bats

# Assertions on the Plymouth splash (splash/) and how the build wires it in.
# The splash only works if every link holds: theme files present and
# self-consistent, plymouth told to use simpledrm (GPU drivers are
# stripped), and nothing allowed to quit plymouth before power-off.

load 'test_helper'

THEME="$BATS_TEST_DIRNAME/../splash/vmcreate"

@test "theme uses the script module with paths matching the install dir" {
    grep -q '^ModuleName=script$' "$THEME/vmcreate.plymouth"
    grep -q '^ImageDir=/usr/share/plymouth/themes/vmcreate$' "$THEME/vmcreate.plymouth"
    grep -q '^ScriptFile=/usr/share/plymouth/themes/vmcreate/vmcreate.script$' "$THEME/vmcreate.plymouth"
}

@test "every image the script loads is shipped" {
    images=$(grep -o 'Image("[^"]*")' "$THEME/vmcreate.script" | sed 's/Image("\(.*\)")/\1/')
    [ -n "$images" ]
    for img in $images; do
        [ -f "$THEME/$img" ] || { echo "missing $img"; return 1; }
    done
}

@test "generated graphics are real PNGs" {
    for img in wordmark.png track.png bar.png cursor.png; do
        head -c 8 "$THEME/$img" | od -An -tx1 | tr -d ' \n' | grep -q '^89504e470d0a1a0a$'
    done
}

@test "script registers the host-facing callbacks" {
    grep -q 'Plymouth.SetDisplayMessageFunction(' "$THEME/vmcreate.script"
    grep -q 'Plymouth.SetHideMessageFunction(' "$THEME/vmcreate.script"
    grep -q 'Plymouth.SetSystemUpdateFunction(' "$THEME/vmcreate.script"
    grep -q 'Plymouth.SetRefreshFunction(' "$THEME/vmcreate.script"
}

@test "script carries the version placeholder build.sh stamps" {
    grep -q '@VMCREATE_ISO_VERSION@' "$THEME/vmcreate.script"
    grep -q 's|@VMCREATE_ISO_VERSION@|' "$PROJECT_ROOT/build.sh"
}

@test "default boot entry enables the splash on simpledrm" {
    entry=$(awk '/^menuentry "VMCreate Deployment ISO" /,/^}/' "$PROJECT_ROOT/grub.cfg")
    echo "$entry" | grep -q ' quiet splash '
    echo "$entry" | grep -q 'plymouth.use-simpledrm'
}

@test "verbose boot entry exists and disables plymouth" {
    entry=$(awk '/verbose, no splash/,/^}/' "$PROJECT_ROOT/grub.cfg")
    echo "$entry" | grep -q 'plymouth.enable=0'
    ! echo "$entry" | grep -q ' splash '
}

@test "build keeps plymouth alive and asserts the theme reached the initrd" {
    grep -q '^systemctl mask plymouth-quit.service plymouth-quit-wait.service getty@tty1.service$' "$PROJECT_ROOT/chroot_setup.sh"
    grep -q 'update-alternatives --set default.plymouth' "$PROJECT_ROOT/chroot_setup.sh"
    grep -q 'ERROR: splash: \$f missing from initrd' "$PROJECT_ROOT/chroot_setup.sh"
    grep -q 'assert_driver "simpledrm.ko"' "$PROJECT_ROOT/chroot_setup.sh"
}
