# M2 — loading real XNU on panther (gsloader v11 scope)

The payload contract is proven by upstream's own phone port (hakios-mt6768
`tools/xl`): the XNUP `kernel` entry carries the **raw XNU Mach-O**
(`BUILD/obj/<CONFIG>_ARM64_BCM2837/mach.development.bcm2837`), no Image
wrapping. Our gsloader must therefore become a Mach-O loader, following
upstream `xnuloader/loader.c` (4370 lines of UEFI app — we port only the
kernel-loading core, ~600 lines, replacing the `ARM\x64` check + `br` jump).

## Contract to port (upstream loader.c → gsloader)

| piece | upstream reference | notes for gs201 |
|---|---|---|
| `mach_header_64` + LC_SEGMENT_64 walk, copy `__TEXT`/`__DATA` to phys | loader.c XNU structures block | kernel linked at `0xfffffff007b04000`-class VA; physical = `KERNEL_LINK_OFFSET` (0x03000000 above payload base) — keep upstream's layout so bootstrap page tables match |
| kernel entry | `LC_UNIXTHREAD` (or `LC_MAIN`) pc | jump target after segment copy + cache clean |
| Apple-format DeviceTree | loader.c DT builder | build from OUR parsed ABL FDT (banks, cpus, chosen) — XNU refuses Linux-format FDT |
| `boot_args` (pexpert/arm64/boot.h) | loader.c | Revision 2, arm64; physical DT pointer, virt/phys base, mem size, cmdline |
| cmdline | `--cmdline` via mkpayload | gs201 first run: `-v` + `cpus=1` (one core, like xnu-cycle's default) |
| cache maintenance | — | clean D-cache + ic iallu to PoC before the jump (MMU off handoff) |
| XNUP entries | mkpayload.py | `kernel=`, `cmdline=`; loader's `physbase`/`rdres` only when RAM disk enters scope |

## Order of work (after the v8/v9/v10 ladder verdict)

1. gsloader v11: accept BOTH payload shapes — `ARM\x64` (stage2 proofs) and
   Mach-O magic `0xfeedfacf` (real kernel) — behind the same `xnup_kernel()`
   walker, then the Mach-O path above.
2. QEMU-verify the loader (the upstream QEMU virt path boots the same payload
   shape; `make qemu-open` is the gate).
3. Phone run: `mkpayload.py kernel=<mach.development.bcm2837> cmdline='-v cpus=1'
   --no-version -o payload.bin` → `mkboot-gs201.sh` → ladder-watch flow.
   Observable: v9's plog proves the jump; XNU's own panic needs the console —
   first runs are 104s-shaped unless XNU's early UART lands.
4. Console: XNU `osfmk/console/` serial backend for gs201 UART0 @0x10A00000
   (exynos UART layout, mainline `earlycon=exynos4210,mmio32`), or the ABL
   splash framebuffer via `/chosen` in the DTB (plog it first: the loader can
   print the chosen framebuffer regs into the ramoops trace).
5. SoC layer (kernel side): `soc/configs/gs201.config` grows
   `CONFIG_SOC_UART_BASE=0x10A00000`, CPU count 8 (2×X1+2×A78+4×A55),
   arch-timer + GIC v3 @0x10400000/0x10440000 facts.

## Facts on file (all verified tonight)

- ABL enters at EL2 (AOSP AVF), MMU state unknown → v10 normalization erets
  to EL1; PSCI reset dead in this context; wdt reset = KEY-locked clusters
  (unlock 0xc0ffee @+0x04) = v8; logs = ramoops console zone = v9.
- gs201 wdt: cl0 0x200c4000 (24s), cl1 0x200c5000 (30s); PMU syscon
  0x18060000; SYSIP_DAT0 +0x0810 writes 0xfa→bootloader on next reset.
- bl_old_log @0xfd880000 = ABL's own account of the previous boot; ramoops
  console @0xfd3ff000 = ours.
