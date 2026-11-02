#!/bin/bash
# build gsloader.bin — bare-metal arm64, no SIMD, strict alignment (device memory until XNU's MMU).
# Needs: theos clang (any real clang works), conda lld (ld.lld), theos llvm-objcopy.
set -e
cd "$(dirname "$0")"
CLANG="${CLANG:-$HOME/theos/toolchain/linux/iphone/bin/clang}"
LD="${LD:-$HOME/.local/lldenv/bin/ld.lld}"
OBJCOPY="${OBJCOPY:-$HOME/theos/toolchain/linux/iphone/bin/llvm-objcopy}"
CFLAGS="--target=aarch64-none-elf -ffreestanding -fno-builtin -fno-stack-protector \
  -mgeneral-regs-only -mstrict-align -O1 -Wall -Wextra -nostdlib"
"$CLANG" $CFLAGS -c start.S -o start.o
"$CLANG" $CFLAGS -c loader.c -o loader.o
"$LD" -T link.ld --build-id=none start.o loader.o -o gsloader.elf
"$OBJCOPY" -O binary gsloader.elf gsloader.bin
ls -la gsloader.bin gsloader.elf
