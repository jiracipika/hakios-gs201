/*
 * probe13 — v12 + reboot-to-recovery preset (closes the evidence loop).
 *
 * v12 (probe at the stock kernel's PE entry) landed in the executing band
 * (~30s), and the Rosetta pulls confirm every ABL-executed kernel (stock AND
 * TWRP's, from boot_b) is an MZ + PE32+ EFI Image — ABL enters via the PE
 * entry point. The v12 marker was eaten by a pstore generation (Android
 * booted after the reset and its console became the "previous boot" log).
 *
 * probe13 fixes that: before arming the watchdog it writes the reboot mode
 * RECOVERY (0xff) to PMU SYSIP_DAT0 (syscon 0x18060000 + 0x0810 = 0x18060810
 * — the same register Linux's gs reboot-mode driver writes from EL1), so the
 * post-reset boot lands in TWRP, whose pstore will expose OUR marker +
 * ABL's x0/x1 as console-ramoops-0 (the previous-boot log). Zero Android
 * root needed; one tap less if "always allow" was ticked.
 *
 * Self-healing outcome matrix:
 *   - marker + PMU + wdt all work -> reset in ms -> recovery boot -> MARKER READABLE
 *   - PMU works, wdt doesn't      -> park; ABL wdt at 104s -> recovery boot -> MARKER READABLE
 *   - first MMIO faults (mapping) -> hang; 104s -> ANDROID boot -> mapping was wrong (learn)
 * Marker at 0xfd3ff000: DBGC, size 32, "V13\n" + raw x0 + raw x1.
 */
.section .text
.global _start
_start:
    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16      /* 0xfd3ff000 ramoops console zone */
    movz    w11, #0x4244
    movk    w11, #0x4347, lsl #16      /* DBGC */
    str     w11, [x10]
    str     wzr, [x10, #4]
    movz    w11, #32
    str     w11, [x10, #8]
    movz    w11, #0x3356
    movk    w11, #0x0a31, lsl #16      /* "V13\n" LE */
    str     w11, [x10, #12]
    str     x0, [x10, #16]             /* ABL x0: image handle (EFI) or DTB ptr */
    str     x1, [x10, #24]             /* ABL x1: system table or 0 */
    dsb     sy

    /* reboot mode = RECOVERY: PMU_ALIVE 0x18060810 (SYSIP_DAT0) = 0xff */
    movz    x24, #0x0810
    movk    x24, #0x1806, lsl #16      /* 0x18060810 */
    movz    w25, #0xff
    str     w25, [x24]
    dsb     sy

    /* arm cl0 @0x200c4000 then cl1 @0x200c5000: KEY unlock, instant violation */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      arm
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      arm
    dsb     sy
1:  wfe
    b       1b

arm:
    movz    w21, #0xffee
    movk    w21, #0xc0, lsl #16        /* 0xc0ffee KEY */
    str     w21, [x20, #4]
    str     wzr, [x20]
    mov     w21, #0x100
    str     w21, [x20, #16]            /* WTMINCNT */
    mov     w21, #0x80
    str     w21, [x20, #8]             /* WTCNT */
    movz    w21, #0x2021
    movk    w21, #0x10, lsl #16        /* WTCON = 0x102021 */
    str     w21, [x20]
    ret
