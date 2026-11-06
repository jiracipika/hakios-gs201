#!/usr/bin/env bash
# mkboot-gs201.sh — package gsloader into boot images that mirror the STOCK Pixel 7
# boot.img shape (rango BP4A.251205.006, decoded 2026-11-04):
#   header v4: header_size 1584 (= v3's 1580 + trailing recovery_ds_size), page 4096,
#              ramdisk 0, os_version 0, cmdline zero-filled 1536
#   kernel:    lz4 LEGACY stream (magic 0x184c2102; stock kernel blob is exactly this,
#              nothing appended)
#   stock container is the full 64MB partition image with AVB0 vbmeta right after the
#   kernel (page-aligned) and an AVBf footer at the end; --avb variant replicates that
#   by patching a copy of the stock boot.img in place (hash mismatch is fine: unlocked).
# Outputs in this directory:
#   panther-boot.img        v4 + lz4 kernel (bare, primary)
#   panther-boot-avb.img    stock 64MB image, header+kernel region swapped (fastboot-boot
#                           shaped exactly like a Magisk-patched stock boot)
#   panther-boot-raw-v4.img v4 + raw kernel (bisect: compression variable)
# usage: mkboot-gs201.sh [/path/to/stock/boot.img]
set -euo pipefail
cd "$(dirname "$0")"
STOCK_BOOT="${1:-}"
LZ4="${LZ4:-$HOME/.local/bin/lz4}"

[ -f gsloader.bin ] || { echo "gsloader.bin missing — run build.sh first"; exit 1; }
[ -x "$LZ4" ] || { echo "lz4 CLI missing at $LZ4 (build lz4/lz4 v1.10, programs/)"; exit 1; }

# magic check on our own image header first
magic=$(dd if=gsloader.bin bs=1 skip=56 count=4 2>/dev/null)
[ "$magic" = "$(printf 'ARM\x64')" ] || { echo "gsloader.bin: no arm64 Image header"; exit 1; }

# ---- optional payload: XNUP appended at __loader_end (16-aligned), res4@0x30 patched ----
BLOB=gsloader.bin
if [ -f payload.bin ]; then
  sig=$(dd if=payload.bin bs=1 count=4 2>/dev/null)
  [ "$sig" = "XNUP" ] || { echo "payload.bin: not an XNUP container (mkpayload.py)"; exit 1; }
  L=$(wc -c < gsloader.bin)
  PADD=$(( (16 - L % 16) % 16 )); POFF=$((L + PADD))
  { cat gsloader.bin; dd if=/dev/zero bs=1 count=$PADD 2>/dev/null; cat payload.bin; } > gsloader-pl.bin
  # u64 LE of POFF into blob offset 0x30 (arm64 Image res4 — the payload offset slot)
  le64() { n=$1; printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x' $((n%256)) $((n/256%256)) $((n/65536%256)) $((n/16777216%256)) $((n/4294967296%256)) 0 0 0)"; }
  le64 $POFF | dd of=gsloader-pl.bin bs=1 seek=$((0x30)) conv=notrunc 2>/dev/null
  BLOB=gsloader-pl.bin
  echo "payload: XNUP $(wc -c < payload.bin) bytes at blob offset $POFF (res4 patched)"
fi

# ---- kernel blob: lz4 legacy (stock Pixel 7 kernel format) ----
"$LZ4" -l -9 -q -f "$BLOB" kernel.lz4
sig=$(xxd -p -l 4 kernel.lz4)
[ "$sig" = "02214c18" ] || { echo "kernel.lz4: not legacy lz4 (magic $sig)"; exit 1; }
KSZ=$(wc -c < kernel.lz4)

le32() { n=$1; printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((n%256)) $((n/256%256)) $((n/65536%256)) $((n/16777216%256)))"; }
mkhdr() { # mkhdr <kernel_size> <header_version> <header_size> <outfile>
  : > "$4"; printf 'ANDROID!' >> "$4"
  le32 "$1" >> "$4"                      # +8  kernel_size
  le32 0    >> "$4"                      # +12 ramdisk_size
  le32 0    >> "$4"                      # +16 os_version
  le32 "$3" >> "$4"                      # +20 header_size (1584 for v4)
  le32 0 >> "$4"; le32 0 >> "$4"; le32 0 >> "$4"; le32 0 >> "$4"   # +24 reserved[4]
  le32 "$2" >> "$4"                      # +40 header_version
  dd if=/dev/zero bs=1536 count=1 >> "$4" 2>/dev/null   # +44 cmdline, zero-filled (stock)
  le32 0 >> "$4"                         # +1580 v4 recovery_ds_size
  dd if=/dev/zero bs=1 count=$((4096-1584)) >> "$4" 2>/dev/null    # pad page to 4096
}

# 1) primary: v4 + lz4
mkhdr "$KSZ" 4 1584 header.tmp
cat header.tmp kernel.lz4 > panther-boot.img

# 2) raw variant (bisect compression variable; no payload — loader-only)
cp gsloader.bin kernel.raw
RAWKSZ=$(wc -c < kernel.raw)
mkhdr "$RAWKSZ" 4 1584 header2.tmp
cat header2.tmp kernel.raw > panther-boot-raw-v4.img
rm -f kernel.raw header2.tmp

# 3) --avb variant: patch a copy of the stock 64MB partition image in place
if [ -n "$STOCK_BOOT" ]; then
  [ -f "$STOCK_BOOT" ] || { echo "stock boot.img not found: $STOCK_BOOT"; exit 1; }
  cp "$STOCK_BOOT" panther-boot-avb.img
  dd if=header.tmp of=panther-boot-avb.img bs=1 seek=0 conv=notrunc 2>/dev/null
  dd if=kernel.lz4 of=panther-boot-avb.img bs=1 seek=4096 conv=notrunc 2>/dev/null
  # zero the region between our kernel end and the stock vbmeta (page-aligned after the
  # STOCK kernel), so nothing of the stock kernel stream survives; vbmeta + footer stay
  # at their recorded offsets (hash mismatch is expected — bootloader is unlocked).
  STOCK_KS=$(od -An -tu4 -j8 -N4 "$STOCK_BOOT" | tr -d ' ')
  KEND=$((4096 + KSZ))
  VBMETA_OFF=$(((4096 + STOCK_KS + 4095) / 4096 * 4096))
  if [ "$KEND" -lt "$VBMETA_OFF" ]; then
    dd if=/dev/zero bs=1 count=$((VBMETA_OFF - KEND)) of=panther-boot-avb.img \
       seek="$KEND" conv=notrunc 2>/dev/null
  fi
  echo "avb variant: stock vbmeta at $VBMETA_OFF kept, our kernel at 4096 (len $KSZ)"
fi
rm -f header.tmp kernel.lz4 gsloader-pl.bin

ls -la panther-boot.img panther-boot-raw-v4.img panther-boot-avb.img 2>/dev/null
