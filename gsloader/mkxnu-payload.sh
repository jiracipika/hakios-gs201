#!/usr/bin/env bash
# mkxnu-payload.sh — M2 pipeline: XNU kernel binary -> XNUP payload -> AVB boot image.
#
# Input: a linked XNU kernel (Mach-O arm64, e.g.
#   xnu-src/xnu-8796.121.2/BUILD/obj/<CONFIG>_ARM64_<MACHINE>/kernel.<config>.<machine>)
# Flow:  objcopy to raw arm64 Image (ARM\x64 header at +0x38) -> XNUP "kernel"
#        entry (upstream mkpayload.py) -> payload.bin in this dir -> mkboot-gs201.sh
#        (auto-append + res4@0x30 patch) -> stock-shaped AVB image -> chain verify.
#
# The gsloader already jumps to the XNUP "kernel" entry with x0 = ABL's DTB; this
# script only swaps the proof payload for the real kernel.
# usage: mkxnu-payload.sh <kernel-binary> [stock-boot.img]
set -euo pipefail
cd "$(dirname "$0")"
KERN="${1:?usage: mkxnu-payload.sh <kernel-binary> [stock-boot.img]}"
STOCK="${2:-/mnt/hdd2/stock/extract/rango-bp4a.251205.006/boot.img}"
OBJCOPY="${OBJCOPY:-$HOME/theos/toolchain/linux/iphone/bin/llvm-objcopy}"
PY=../../../xnuloader/mkpayload.py

[ -f "$KERN" ] || { echo "kernel binary not found: $KERN"; exit 1; }
[ -x "$OBJCOPY" ] || { echo "objcopy missing at $OBJCOPY"; exit 1; }
[ -f payload.bin ] && cp payload.bin /tmp/payload-prev.bin

# 1) raw arm64 Image
"$OBJCOPY" -O binary "$KERN" /tmp/xnu-image.raw
magic=$(dd if=/tmp/xnu-image.raw bs=1 skip=56 count=4 2>/dev/null)
[ "$magic" = "$(printf 'ARM\x64')" ] || { echo "no arm64 Image header at +0x38"; exit 1; }
SZ=$(wc -c < /tmp/xnu-image.raw)
echo "kernel Image: $SZ bytes"

# 2) XNUP payload ("kernel" entry, no version entry — loader skips unknown ones,
#    but keep it explicit: the kernel itself is the only entry)
python3 "$PY" kernel=/tmp/xnu-image.raw --no-version -o payload.bin
POFFCHECK=$(od -An -tu4 -j24 -N4 payload.bin | tr -d ' ')
echo "payload kernel-entry size: $POFFCHECK bytes"

# 3) boot image (stock-shaped AVB variant — the proven fastboot-boot shape)
rm -f payload.prev; bash mkboot-gs201.sh "$STOCK" | grep -E "payload|avb variant"
cp panther-boot-avb.img panther-boot-xnu.img

# 4) chain verify inside the final image
LZ="${LZ4:-$HOME/.local/bin/lz4}"
KSZ=$(od -An -tu4 -j8 -N4 panther-boot-xnu.img | tr -d ' ')
dd if=panther-boot-xnu.img of=/tmp/mxp.lz4 bs=1 skip=4096 count="$KSZ" 2>/dev/null
"$LZ" -d -q /tmp/mxp.lz4 /tmp/mxp.bin 2>/dev/null || "$LZ" -d /tmp/mxp.lz4 /tmp/mxp.bin >/dev/null
POFF=$(od -An -tu8 -j48 -N8 /tmp/mxp.bin | tr -d ' ')
[ "$(dd if=/tmp/mxp.bin bs=1 skip="$POFF" count=4 2>/dev/null | xxd -p)" = "584e5550" ] \
  || { echo "CHAIN BROKEN: no XNUP at $POFF"; exit 1; }
KENT=$((POFF + 32))
[ "$(dd if=/tmp/mxp.bin bs=1 skip=$((KENT+56)) count=4 2>/dev/null | xxd -p)" = "41524d64" ] \
  || { echo "CHAIN BROKEN: no ARM\\x64 at kernel entry +0x38"; exit 1; }
echo "CHAIN OK: res4=$POFF XNUP ok kernel-entry ARM\\x64 ok -> panther-boot-xnu.img"
