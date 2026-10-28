#!/usr/bin/env bash
# Build the LDY-AN00 GhostLock exploit and the su broker from source.
#
# Output goes outside the repository by default, so the GitHub repo stays
# code-only:
#   ${XDG_CACHE_HOME:-$HOME/.cache}/ghostlock-ldy-an00/device_root_aarch64
#   ${XDG_CACHE_HOME:-$HOME/.cache}/ghostlock-ldy-an00/su
# Pass explicit output paths as $1 (exploit) and $2 (su) to override.
#
# The phone-verified exploit build used:
#   aarch64-linux-gnu-gcc -static -O1 -pthread -I exploit \
#       -o <out> exploit/device_root.c
# Reference SHA-256 of that build:
#   d0d72f0379d91971152cac7a970001c6b1057296ea5b38b87866baa21e4de9ab
# A different GCC may produce a different hash for the same source.
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-aarch64-linux-gnu-gcc}"
REF_SHA="d0d72f0379d91971152cac7a970001c6b1057296ea5b38b87866baa21e4de9ab"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ghostlock-ldy-an00"
OUT="${1:-$CACHE_DIR/device_root_aarch64}"
SU_OUT="${2:-$CACHE_DIR/su}"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "error: cross compiler '$CC' not found." >&2
    echo "       install gcc-aarch64-linux-gnu, or set CC=/path/to/aarch64-linux-gnu-gcc" >&2
    exit 1
fi
[ -f exploit/device_root.c ] && [ -f su/su.c ] || {
    echo "error: exploit/device_root.c or su/su.c missing (run from the repository root)" >&2
    exit 1
}

mkdir -p "$(dirname "$OUT")" "$(dirname "$SU_OUT")"
echo "[*] compiling exploit/device_root.c with $CC"
"$CC" -static -O1 -pthread -I exploit -o "$OUT" exploit/device_root.c
echo "[*] compiling su/su.c with $CC"
"$CC" -static -O2 -o "$SU_OUT" su/su.c

sha=$(sha256sum "$OUT" | awk '{print $1}')
su_sha=$(sha256sum "$SU_OUT" | awk '{print $1}')
echo
echo "[+] built:  $OUT"
echo "[+] sha256: $sha"
echo "[+] phone-verified reference: $REF_SHA"
if [ "$sha" = "$REF_SHA" ]; then
    echo "[+] byte-identical to the phone-verified exploit binary"
else
    echo "[!] exploit hash differs from the reference (toolchain difference); same source."
fi
echo "[+] built:  $SU_OUT"
echo "[+] sha256: $su_sha (su broker/daemon)"
