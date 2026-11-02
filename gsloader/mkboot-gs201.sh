#!/usr/bin/env bash
# mkboot-gs201.sh — package gsloader into an Android boot image, header v3 (page 4096),
# for `fastboot boot` on Pixel 7. Nothing is flashed; `fastboot boot` is a RAM session.
#
# v3 header layout (AOSP boot_img_hdr_v3, 1580 bytes, no `id` field):
#   magic[8] kernel_size ramdisk_size os_version header_size reserved[4] header_version cmdline[1536]
#
# Inputs (fixed names, this directory): gsloader.bin, optional payload.bin (XNUP, --with-payload)
# Output: panther-boot.img in this directory.
#
# usage: mkboot-gs201.sh [--with-payload]
set -euo pipefail
cd "$(dirname "$0")"

WITH_PAYLOAD=0
[ "${1:-}" = "--with-payload" ] && WITH_PAYLOAD=1

[ -f gsloader.bin ] || { echo "gsloader.bin missing — run build.sh first"; exit 1; }

LOAD="$(wc -c < gsloader.bin)"
magic=$(dd if=gsloader.bin bs=1 skip=56 count=4 2>/dev/null)
[ "$magic" = "$(printf 'ARM\x64')" ] || { echo "gsloader.bin: no arm64 Image header"; exit 1; }

# ---- optional payload: XNUP appended 16-aligned, res3 (offset 0x30) = its offset ----
BLOB=gsloader.bin
if [ "$WITH_PAYLOAD" = 1 ]; then
  [ -f payload.bin ] || { echo "payload.bin missing"; exit 1; }
  sig=$(dd if=payload.bin bs=1 count=4 2>/dev/null)
  [ "$sig" = "XNUP" ] || { echo "payload.bin is not an XNUP container"; exit 1; }
  PAYLOAD_OFF=$(( LOAD + (16 - LOAD % 16) % 16 ))
  cat gsloader.bin <(printf '%*s' "$(( PAYLOAD_OFF - LOAD ))" '') payload.bin > gsloader-pl.bin
  n=$PAYLOAD_OFF
  le64() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x' $((n%256)) $((n/256%256)) $((n/65536%256)) $((n/16777216%256)) $((n/4294967296%256)) $((n/1099511627776%256)) $((n/281474976710656%256)) $((n/72057594037927936%256)))"; }
  le64 | dd of=gsloader-pl.bin bs=1 seek=48 conv=notrunc 2>/dev/null
  BLOB=gsloader-pl.bin
  LOAD="$(wc -c < "$BLOB")"
fi

gzip -9 -n -c "$BLOB" > kernel.gz
KSZ="$(wc -c < kernel.gz)"

# ---- v3 header, correct layout ----
le32() { n=$1; printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((n%256)) $((n/256%256)) $((n/65536%256)) $((n/16777216%256)))"; }
hdr=header.tmp; : > "$hdr"
printf 'ANDROID!' >> "$hdr"
le32 $KSZ >> "$hdr"                    # +8  kernel size (gzip of the loader blob)
le32 0 >> "$hdr"                       # +12 ramdisk size
le32 0 >> "$hdr"                       # +16 os_version
le32 1580 >> "$hdr"                    # +20 header_size = 1580 (v3)
le32 0 >> "$hdr"; le32 0 >> "$hdr"; le32 0 >> "$hdr"; le32 0 >> "$hdr"   # +24 reserved[4]
le32 3 >> "$hdr"                       # +40 header_version = 3
printf '%-1536s' '' >> "$hdr"          # +44 cmdline[1536], zeros
# 8+4*10+1536 = 1580 exactly; pad the page with zeros to 4096
dd if=/dev/zero bs=1 count=$((4096 - 1580)) >> "$hdr" 2>/dev/null

cat "$hdr" kernel.gz > panther-boot.img
rm -f kernel.gz "$hdr"
[ "$BLOB" = gsloader-pl.bin ] && rm -f gsloader-pl.bin
ls -la panther-boot.img
