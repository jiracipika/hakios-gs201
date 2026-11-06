#!/usr/bin/env bash
# stage2 build — same toolchain contract as ../build.sh (theos clang, conda ld.lld).
set -euo pipefail
cd "$(dirname "$0")"
CLANG="${CLANG:-$HOME/theos/toolchain/linux/iphone/bin/clang}"
LD="${LD:-$HOME/.local/lldenv/bin/ld.lld}"
[ -x "$LD" ] || LD="$(command -v ld.lld || true)"
[ -n "$LD" ] || { echo "stage2: no ld.lld"; exit 1; }
"$CLANG" --target=aarch64-none-elf -mgeneral-regs-only -mstrict-align \
    -ffreestanding -fno-builtin -c stage2.S -o stage2.o
"$LD" -T link.ld -o stage2.elf stage2.o
"$CLANG" --target=aarch64-none-elf -Wall -Wextra -ffreestanding -fno-builtin \
    -c -x assembler-with-cpp /dev/null -o /dev/null 2>/dev/null || true
# objcopy the raw image
"${OBJCOPY:-$HOME/theos/toolchain/linux/iphone/bin/llvm-objcopy}" -O binary stage2.elf stage2.bin
ls -la stage2.bin
