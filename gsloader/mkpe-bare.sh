#!/usr/bin/env bash
# mkpe-bare.sh — the ramdisk-delivery vehicle (proven accepted by ABL).
#
# ABL executes the kernel stream only when it is (nearly) stock-exact:
# the full stock kernel plus a <=64KB patch at the PE entry (AEP) works;
# bigger modifications always die on ABL's watchdog no matter the content,
# compression size, block count, or zero-run structure (16-run bisection,
# 2026-11-06). This build therefore:
#   kernel  = full stock decompressed + stage2/m2ld.bin at AEP, lz4 legacy
#   ramdisk = the GSPE blob (manifest + raw XNU Mach-O), lz4 legacy
#   header  = bare Android boot v4 (no vbmeta, no AVB footer — accepted)
# m2ld finds the GSPE via FDT /chosen/linux,initrd-* or a DRAM scan.
set -euo pipefail
cd "$(dirname "$0")"

LZ4="${LZ4:-$HOME/.local/bin/lz4}"
STOCK="${1:-/mnt/hdd2/stock/extract/rango-bp4a.251205.006/boot.img}"
AEP=0x1d2a458
SZIMG=0x22e7a00

[ -x "$LZ4" ] || { echo "lz4 missing"; exit 1; }
[ -f stage2/m2ld.bin ] || { echo "run build-m2ld.sh first"; exit 1; }

T=$(mktemp -d /tmp/mkpb-XXXXXX)
trap 'rm -rf "$T"' EXIT

# stock kernel headers+content (decompress the stock stream)
STOCK_KS=$(od -An -tu4 -j8 -N4 "$STOCK" | tr -d ' ')
dd if="$STOCK" of="$T/sk.lz4" bs=1 skip=4096 count="$STOCK_KS" status=none
"$LZ4" -d -q -f "$T/sk.lz4" "$T/sk.bin"

# kernel vehicle: stock-exact + m2ld at AEP
cp "$T/sk.bin" "$T/veh.bin"
truncate -s $((SZIMG)) "$T/veh.bin"
dd if=stage2/m2ld.bin of="$T/veh.bin" bs=1 seek=$((AEP)) status=none conv=notrunc
"$LZ4" -l -9 -q -f "$T/veh.bin" "$T/veh.lz4"
KERN=$(wc -c < "$T/veh.lz4")

# ramdisk: GSPE blob
python3 mkpe-manifest.py < "${KERN_SRC:-/tmp/panther-kernel-bcm2837}" > "$T/gspe.bin" 2>"$T/gspe.info"
cat "$T/gspe.info"
"$LZ4" -l -9 -q -f "$T/gspe.bin" "$T/rd.lz4"
RD=$(wc -c < "$T/rd.lz4")

# bare v4 image
le32() { n=$1; printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((n%256)) $((n/256%256)) $((n/65536%256)) $((n/16777216%256)))"; }
{
  printf 'ANDROID!'
  le32 "$KERN"; le32 "$RD"; le32 0; le32 1584
  le32 0; le32 0; le32 0; le32 0
  le32 4
  dd if=/dev/zero bs=1536 count=1 status=none
  le32 0
  dd if=/dev/zero bs=1 count=$((4096-1584)) status=none
} > "$T/hdr"
cat "$T/hdr" "$T/veh.lz4" > panther-boot-bare-rd.img
dd if=/dev/zero bs=1 count=$(( (4096 - KERN % 4096) % 4096 )) >> panther-boot-bare-rd.img 2>/dev/null
cat "$T/rd.lz4" >> panther-boot-bare-rd.img

# verify: kernel decompresses with our blob at AEP
dd if=panther-boot-bare-rd.img of="$T/vk.lz4" bs=1 skip=4096 count="$KERN" status=none
"$LZ4" -d -q -f "$T/vk.lz4" "$T/vk.bin"
python3 - "$T/vk.bin" stage2/m2ld.bin <<'PYV'
import sys
v=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
AEP=0x1d2a458
assert len(v)>=0x22e7a00, "kernel short"
assert v[AEP:AEP+len(b)]==b, "blob mismatch"
print("verify: m2ld at AEP ok,", len(b), "bytes")
PYV
VOFF=$(nm stage2/m2ld.elf | awk '$3=="m2_vectors"{print $1}' | head -1)
[ $(( (AEP + 0x$VOFF) % 0x80 )) -eq 0 ] || { echo "vectors misaligned"; exit 1; }
echo "CHAIN OK -> panther-boot-bare-rd.img (kernel $KERN, ramdisk $RD, total $(wc -c < panther-boot-bare-rd.img))"
