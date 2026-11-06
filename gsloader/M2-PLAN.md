# M2-PLAN — XNU load on the PE vehicle (rev 3, 2026-11-06 post-gate-solve)

Supersedes rev 2 (the ARM\x64-check / classic-Image scope died with the ABL gate work).

## Where we stand
- **Delivery SOLVED**: `mkpe-bare.sh` — bare Android boot v4 image, kernel stream =
  full stock + m2ld@AEP (≤64KB patch, the only modification ABL tolerates), XNU payload
  in the **ramdisk** field (GSPE, 6.9MB compressed). Accepted by `fastboot boot`.
- m2ld v8: full path runs on hardware (entry → plog → regs → GSPE-find → window →
  copy → Apple DT → boot_args → clean → XNULDRST stub → calibrated wdt → jump).
- Observability: bands 30s (error path) / ~50-55s (XNU checkpoint 1 = kernel code ran) /
  ~75-80s (jump + 45s window) / 104-106s (hang). plog rings survive short runs.

## The ABL gate (why the ramdisk vehicle exists)
ABL executes the decompressed kernel only when it is (nearly) stock-exact: ≤64KB of
modification is tolerated (wherever), ≥~768KB anywhere floors on ABL's own watchdog —
independent of compressed size, lz4 block count, zero-run structure, or location
(16-run bisection 2026-11-06). All "big payload inside the kernel stream" designs are
dead; the ramdisk field is the channel.

## Immediate next steps
1. Read the plog from the first full-path run (error branch at 30s — which error?):
   pmsg-ramoops-0 from TWRP (needs the auth tap; Suzy-Q UART would retire this dance).
2. GSPE discovery fix if B1 (no-gspe): the 1MiB-step scan can miss an unaligned ramdisk
   start — go to 4KiB steps and/or trust the FDT /chosen/linux,initrd-* values. If the
   ramdisk turns out compressed-in-place (ABL passing it raw), handle both.
3. On first ~75-80s or ~50-55s band: XNU is IN — then milestone ladder: checkpoint
   returns → early console (gs201 USI UART driver in the kernel fork) → panic visible.
4. Vehicle knobs if needed: ramdisk_size is unconstrained; multi-MB payloads fine.

## Banked constraints (do not relearn)
- MMU stays ON under ABL's identity map; SCTLR untouched; EL2→EL1h via eret.
- No CNTPCT/CNTFRQ waits (trapped/frozen in fastboot handoff) — iteration loops only.
- Stack = img+0x1c40000 (self − 0xea458). VBAR table runtime 0x80-aligned.
- XNULDRST slot VA 0xfffffff0074097f0; entry 0xfffffff0074084a8; KVB 0xfffffff004000000.
- WDT: KEY 0xc0ffee @+4, prescale 0x20 (÷528 ≈ 46.5kHz @ PCLK 24.576MHz), RSTEN|ENABLE|
  DBGACK(0x102021); count-only 0x102020 for calibration; both clusters 0x200c4000/5000.
