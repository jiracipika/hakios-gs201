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
M2LD="${M2LD:-stage2/m2ld.bin}"
AEP=0x1d2a458
SZIMG=0x22e7a00

[ -x "$LZ4" ] || { echo "lz4 missing"; exit 1; }
[ -f "$M2LD" ] || { echo "loader blob missing: $M2LD"; exit 1; }

T=$(mktemp -d /tmp/mkpb-XXXXXX)
trap 'rm -rf "$T"' EXIT

# stock kernel headers+content (decompress the stock stream)
STOCK_KS=$(od -An -tu4 -j8 -N4 "$STOCK" | tr -d ' ')
dd if="$STOCK" of="$T/sk.lz4" bs=1 skip=4096 count="$STOCK_KS" status=none
"$LZ4" -d -q -f "$T/sk.lz4" "$T/sk.bin"

# GSPE blob first (the vehicle embeds it)
python3 mkpe-manifest.py < "${KERN_SRC:-/tmp/panther-kernel-bcm2837}" > "$T/gspe.bin" 2>"$T/gspe.info"
cat "$T/gspe.info"

# kernel vehicle: stock-exact + GSPE + m2ld at AEP.
# BIG=1 (default): 128 MiB decompressed image — the XNU window (48 MiB gap +
# ~19 MiB kernel) fits INSIDE the decompressed buffer, which ABL maps by
# construction. Everything past the stock content is a repeating 4 KiB
# pseudorandom block (compresses to ~nothing, breaks no zero-run rules).
# The classic Image image_size (@0x08) and PE SizeOfImage (@0x90) both get
# the new size so ABL sizes its buffer correctly.
BIGVEH_SZ=0x8000000
cp "$T/sk.bin" "$T/veh.bin"
truncate -s $((BIGVEH_SZ)) "$T/veh.bin"
python3 - "$T/veh.bin" "$T/gspe.bin" <<'PYB'
import sys, os, struct
veh, gspe = sys.argv[1], sys.argv[2]
AEP = 0x1d2a458
GSPE_OFF = 0x0200000
SZ = 0x8000000
d = bytearray(open(veh, 'rb').read())
d[GSPE_OFF:GSPE_OFF+len(open(gspe,'rb').read())] = open(gspe,'rb').read()
m2 = open(os.environ.get('M2LD', 'stage2/m2ld.bin'), 'rb').read()
d[AEP:AEP+len(m2)] = m2
# filler: repeating 4 KiB pseudorandom block from stock end to image end
pat = os.urandom(4096)
off = 0x22e8000
while off < SZ:
    d[off:off+4096] = pat
    off += 4096
# headers: classic image_size @0x08 (u64), PE SizeOfImage @0x90 (u32)
struct.pack_into('<Q', d, 0x08, SZ)
struct.pack_into('<I', d, 0x90, SZ)
open(veh, 'wb').write(d)
print("big vehicle: gspe+m2ld+filler, image_size ->", hex(SZ))
PYB
"$LZ4" -l -9 -q -f "$T/veh.bin" "$T/veh.lz4"
KERN=$(wc -c < "$T/veh.lz4")

# no ramdisk in the big-vehicle flow: the GSPE rides inside the kernel image
RD=0

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

# verify: kernel decompresses with our blob at AEP
dd if=panther-boot-bare-rd.img of="$T/vk.lz4" bs=1 skip=4096 count="$KERN" status=none
"$LZ4" -d -q -f "$T/vk.lz4" "$T/vk.bin"
python3 - "$T/vk.bin" "$M2LD" <<'PYV'
import sys
v=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
AEP=0x1d2a458
assert len(v)>=0x22e7a00, "kernel short"
assert v[AEP:AEP+len(b)]==b, "blob mismatch"
print("verify: m2ld at AEP ok,", len(b), "bytes")
PYV
VOFF=$(nm "${M2LD%.bin}.elf" 2>/dev/null | awk '$3=="m2_vectors" || $3=="m8_vectors" {print $1}' | head -1)
if [ -n "$VOFF" ]; then
  [ $(( (AEP + 0x$VOFF) % 0x80 )) -eq 0 ] || { echo "vectors misaligned"; exit 1; }
fi
echo "CHAIN OK -> panther-boot-bare-rd.img (kernel $KERN, ramdisk $RD, total $(wc -c < panther-boot-bare-rd.img))"
