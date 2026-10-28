#!/system/bin/sh
# Executed by the escalated exploit child (uid 0, SID u:r:kernel:s0,
# SELinux permissive).  Starts the root su daemon, then gives this adb session
# an interactive root shell.
#
# After this runs, any other adb shell (uid 2000) can use:
#   /data/local/tmp/su
#   /data/local/tmp/su -c 'id'
BIN=/data/local/tmp/su
if [ -x "$BIN" ]; then
    chown 0:0 "$BIN" 2>/dev/null
    chmod 755 "$BIN" 2>/dev/null
    "$BIN" --daemon >/dev/null 2>&1
fi
exec /system/bin/sh -i
