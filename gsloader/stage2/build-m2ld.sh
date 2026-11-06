#!/usr/bin/env bash
# build-m2ld.sh — M2 PE-vehicle loader blob (m2ld.S + m2ld.c -> m2ld.bin).
# Same toolchain contract as build.sh: theos clang, conda ld.lld, no SIMD,
# strict alignment (all memory is device-grade until XNU's MMU comes up).
set -euo pipefail
cd "$(dirname "$0")"
CLANG="${CLANG:-$HOME/theos/toolchain/linux/iphone/bin/clang}"
LD="${LD:-$HOME/.local/lldenv/bin/ld.lld}"
[ -x "$LD" ] || LD="$(command -v ld.lld || true)"
[ -n "$LD" ] || { echo "m2ld: no ld.lld"; exit 1; }
OBJCOPY="${OBJCOPY:-$HOME/theos/toolchain/linux/iphone/bin/llvm-objcopy}"

"$CLANG" --target=aarch64-none-elf -mgeneral-regs-only -mstrict-align \
    -ffreestanding -fno-builtin -O2 -Wall -Wextra -c m2ld.S -o m2ld_asm.o
"$CLANG" --target=aarch64-none-elf -mgeneral-regs-only -mstrict-align \
    -ffreestanding -fno-builtin -O2 -Wall -Wextra -c m2ld.c -o m2ld_c.o
"$LD" -T m2ld.ld -o m2ld.elf m2ld_asm.o m2ld_c.o
"$OBJCOPY" -O binary m2ld.elf m2ld.bin

SZ=$(wc -c < m2ld.bin)
if [ "$SZ" -gt $((0x5B5BA8)) ]; then     # image end (0x22e7a00) - AEP
    echo "m2ld.bin too big: $SZ"; exit 1
fi
echo "m2ld.bin: $SZ bytes"
