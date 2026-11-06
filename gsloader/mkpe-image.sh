#!/usr/bin/env bash
# mkpe-image.sh — M2: PE-vehicle boot image carrying the real XNU kernel.
#
# Vehicle (silicon-proven shape): stock kernel bytes 0x0..0x10000 verbatim
# (classic Image header + PE32+ headers for ABL's parser), zeros to the stock
# PE SizeOfImage, plus:
#   +0x0200000  GSPE blob   (mkpe-manifest.py: manifest + raw Mach-O)
#   +0x1180000  pram        (XNU panic-log target, 512 KiB)
#   +0x1c40000  stack top   (256 KiB down)
#   +0x1d2a458  m2ld.bin    (our loader, at the stock AddressOfEntryPoint)
# then lz4-legacy compress and splice into the stock 64MB AVB container
# (same recipe as mkboot-gs201.sh) and verify the chain end to end.
#
# usage: mkpe-image.sh <kernel-macho> <stock-boot.img>
#   kernel default: /tmp/panther-kernel-bcm2837
#   stock default:  the decoded rango boot.img
set -euo pipefail
cd "$(dirname "$0")"

KERN="${1:-/tmp/panther-kernel-bcm2837}"
STOCK="${2:-/mnt/hdd2/stock/extract/rango-bp4a.251205.006/boot.img}"
LZ4="${LZ4:-$HOME/.local/bin/lz4}"
NM="${NM:-nm}"

AEP=0x1d2a458
SIZEOFIMG=0x22e7a00
GSPE_OFF=0x0200000
PRAM_OFF=0x1180000
VBMETA_OFF_EXPECT=$((0x1068000))

[ -f "$KERN" ]  || { echo "kernel not found: $KERN"; exit 1; }
[ -f "$STOCK" ] || { echo "stock boot.img not found: $STOCK"; exit 1; }
[ -x "$LZ4" ]   || { echo "lz4 missing at $LZ4"; exit 1; }
[ -f stage2/m2ld.bin ] || { echo "stage2/m2ld.bin missing — run build-m2ld.sh"; exit 1; }

T=$(mktemp -d /tmp/mkpe-XXXXXX)
trap 'rm -rf "$T"' EXIT

# ---- 1) GSPE blob (manifest + raw kernel), diagnostics visible ----
python3 mkpe-manifest.py < "$KERN" > "$T/gspe.bin" 2>"$T/gspe.info"
cat "$T/gspe.info"
grep -q "entry=0x" "$T/gspe.info" || { echo "manifest build failed"; exit 1; }
GSPE_SZ=$(wc -c < "$T/gspe.bin")
GSPE_END=$((GSPE_OFF + GSPE_SZ))
[ "$GSPE_END" -le $((PRAM_OFF)) ] || { echo "GSPE ($GSPE_SZ B) overruns pram at $PRAM_OFF"; exit 1; }
ENTRY=$(sed -n 's/.*entry=0x\([0-9a-f]*\).*/\1/p' "$T/gspe.info" | head -1)
STUB=$(sed -n 's/.*stub_slot=0x\([0-9a-f]*\).*/\1/p' "$T/gspe.info" | head -1)

# ---- 2) stock kernel headers (decompress the stock lz4 stream) ----
STOCK_KS=$(od -An -tu4 -j8 -N4 "$STOCK" | tr -d ' ')
VBMETA_OFF=$(((4096 + STOCK_KS + 4095) / 4096 * 4096))
[ "$VBMETA_OFF" -eq "$VBMETA_OFF_EXPECT" ] || echo "NOTE: stock vbmeta at $VBMETA_OFF (expected $VBMETA_OFF_EXPECT)"
dd if="$STOCK" of="$T/stock-k.lz4" bs=1 skip=4096 count="$STOCK_KS" status=none
"$LZ4" -d -q -f "$T/stock-k.lz4" "$T/stock-k.bin"
STOCK_KSZ=$(wc -c < "$T/stock-k.bin")
# stock stream ends ~12KB below PE SizeOfImage; we only need its headers
[ "$STOCK_KSZ" -ge $((0x10000)) ] || { echo "stock kernel decompressed short: $STOCK_KSZ"; exit 1; }

# ---- 3) vehicle: zeros + stock headers + GSPE + m2ld ----
truncate -s $((SIZEOFIMG)) "$T/veh.bin"
dd if="$T/stock-k.bin" of="$T/veh.bin" bs=1 seek=0 count=$((0x10000)) status=none conv=notrunc
dd if="$T/gspe.bin" of="$T/veh.bin" bs=1 seek=$((GSPE_OFF)) status=none conv=notrunc
dd if=stage2/m2ld.bin of="$T/veh.bin" bs=1 seek=$((AEP)) status=none conv=notrunc

# ---- 4) lz4 legacy + splice into the AVB container ----
"$LZ4" -l -9 -q -f "$T/veh.bin" "$T/veh.lz4"
[ "$(xxd -p -l 4 "$T/veh.lz4")" = "02214c18" ] || { echo "not lz4-legacy"; exit 1; }
KSZ=$(wc -c < "$T/veh.lz4")
BUDGET=$((VBMETA_OFF - 4096))
[ "$((4096 + KSZ))" -le "$VBMETA_OFF" ] || { echo "compressed $KSZ overruns vbmeta (budget $BUDGET)"; exit 1; }
echo "compressed vehicle: $KSZ bytes (budget $BUDGET)"

cp "$STOCK" panther-boot-avb-xnu.img
le32() { n=$1; printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((n%256)) $((n/256%256)) $((n/65536%256)) $((n/16777216%256)))"; }
{
  printf 'ANDROID!'
  le32 "$KSZ"; le32 0; le32 0; le32 1584
  le32 0; le32 0; le32 0; le32 0
  le32 4
  dd if=/dev/zero bs=1536 count=1 status=none
  le32 0
  dd if=/dev/zero bs=1 count=$((4096-1584)) status=none
} > "$T/hdr"
dd if="$T/hdr" of=panther-boot-avb-xnu.img bs=1 seek=0 conv=notrunc status=none
dd if="$T/veh.lz4" of=panther-boot-avb-xnu.img bs=1 seek=4096 conv=notrunc status=none
dd if=/dev/zero of=panther-boot-avb-xnu.img bs=1 seek=$((4096+KSZ)) count=$((VBMETA_OFF-4096-KSZ)) conv=notrunc status=none

# ---- 5) chain verify ----
dd if=panther-boot-avb-xnu.img of="$T/v.lz4" bs=1 skip=4096 count="$KSZ" status=none
"$LZ4" -d -q -f "$T/v.lz4" "$T/v.bin"
V=$(wc -c < "$T/v.bin")
[ "$V" -eq $((SIZEOFIMG)) ] || { echo "CHAIN BROKEN: decompressed $V != $((SIZEOFIMG))"; exit 1; }
[ "$(dd if="$T/v.bin" bs=1 skip=0 count=4 status=none | xxd -p)" = "$(dd if="$T/stock-k.bin" bs=1 skip=0 count=4 status=none | xxd -p)" ] \
  || { echo "CHAIN BROKEN: header magic mismatch"; exit 1; }
[ "$(dd if="$T/v.bin" bs=1 skip=$((GSPE_OFF)) count=6 status=none)" = "GSPE01" ] \
  || { echo "CHAIN BROKEN: no GSPE magic in vehicle"; exit 1; }
VENTRY=$(od -An -tx8 -j $((GSPE_OFF+24)) -N8 "$T/v.bin" | tr -d ' ')
[ "0x$VENTRY" = "0x$ENTRY" ] || { echo "CHAIN BROKEN: entry $VENTRY != $ENTRY"; exit 1; }
VOFF=$("$NM" stage2/m2ld.elf | awk '$3=="m2_vectors"{print $1}' | head -1)
if [ -n "$VOFF" ]; then
  RUNT=$((AEP + 0x$VOFF))
  [ $((RUNT % 0x80)) -eq 0 ] || { echo "CHAIN BROKEN: m2_vectors runtime misaligned ($RUNT % 0x80 != 0)"; exit 1; }
  echo "m2_vectors blob+0x$VOFF -> runtime 0x$(printf %x $((0x80000000+RUNT))) (0x80-aligned)"
else
  echo "NOTE: m2_vectors offset unchecked (nm)"
fi
diff <(dd if="$T/v.bin" bs=1 skip=$((AEP)) count=$(wc -c < stage2/m2ld.bin) status=none) stage2/m2ld.bin >/dev/null \
  || { echo "CHAIN BROKEN: m2ld blob mismatch"; exit 1; }

echo "gspe: $GSPE_SZ B at +0x$(printf %x $GSPE_OFF) (ends 0x$(printf %x $GSPE_END)) entry=0x$ENTRY stub=0x${STUB:-0}"
echo "CHAIN OK -> panther-boot-avb-xnu.img ($(wc -c < panther-boot-avb-xnu.img) B, kernel $KSZ B lz4)"
