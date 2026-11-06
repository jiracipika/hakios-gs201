/*
 * stage2 — the M1 payload proof (Pixel 7 / gs201), v3.
 *
 * Silicon evidence so far (2026-11-06 night):
 *  - ABL runs the loader (M0: loader DTB-parse + reset attempt).
 *  - PSCI SYSTEM_RESET silently no-ops from the ABL fastboot-boot context
 *    (SMC and HVC both return without effect).
 *  - v2 armed BOTH cluster watchdogs with the kernel emergency-restart recipe
 *    (s3c2410wdt_restart, gs s3c2410_wdt.c) — and the outcome was identical to
 *    loader-only (104s comeback, bootreason watchdog,apc,early). Since v2's
 *    first write CLEARS WTCON (which would have disarmed ABL's watchdog and
 *    parked the phone forever), yet ABL's watchdog still fired on schedule,
 *    the writes never took effect: front-runner hypothesis = ABL hands off
 *    with the MMU ON (start.S's "MMU off at handoff" was an assumption), our
 *    wdt MMIO write faults -> gsloader_trap -> PSCI-park -> ABL watchdog fires
 *    untouched.
 *
 * v3: turn the MMU off OURSELVES first (EL2 sctlr only if CurrentEL==EL2;
 * EL1 sctlr always), invalidate icache, then arm both cluster watchdogs for
 * the instant windowed violation -> hard reset in milliseconds.
 *
 * GREEN = adb back in ~45-55s (reset ~0s after payload entry). 104s again =
 * the payload branch never reaches the wdt writes (jump-path bug in the
 * loader — next suspect is xnup_find/xnup_kernel offset math).
 */
.section .text.boot
.global _start
_start:
    /* Linux arm64 Image header so gsloader's check (ARM\x64 at +0x38) passes */
    b       entry
    .word   0
    .quad   0x80000                 /* text_offset */
    .quad   0x1000                  /* image_size (covering) */
    .quad   0x0a                    /* flags: LE, 4K, anywhere */
    .quad   0                       /* res2 */
    .quad   0                       /* res3 */
    .quad   0                       /* res4 */
    .ascii  "ARM\x64"
    .word   0

entry:
    msr     daifset, #0xf
    mov     x19, x0                 /* ABL's DTB — the contract proof (unused here) */

    /* v3 preamble: MMU/caches off, by our own hand. EL2 sctlr only if we're
       at EL2 (msr sctlr_el2 at EL1 is undefined → trap → park). This is the
       first un-assumption: ABL's handoff state is what it is; we stop
       inheriting it. */
    dsb     sy
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.ne    5f
    msr     sctlr_el2, xzr
    isb
5:  msr     sctlr_el1, xzr
    isb
    ic      iallu
    dsb     sy
    isb

    /* s3c2410wdt_restart() recipe on both cluster watchdogs, immediately */
    movz    x0, #0x4000
    movk    x0, #0x200c, lsl #16     /* cl0: watchdog_cl0@200c4000 */
    bl      arm_wdt
    movz    x0, #0x5000
    movk    x0, #0x200c, lsl #16     /* cl1: watchdog_cl1@200c5000 */
    bl      arm_wdt
    dsb     sy

3:  wfe
    b       3b                       /* reset asserts in ~ms; park as fallback */

/*
 * arm_wdt — s3c2410wdt_restart() register recipe for one cluster block.
 * x0 = block base. Offsets: WTCON 0x00, WTDAT 0x04, WTCNT 0x08, WTMINCNT 0x10.
 * WTCON value: ENABLE(bit5) | RSTEN(bit0) | DIV16(0<<3) | PRESCALE(0x20)<<8 |
 *              WINDOWED(bit20) = 0x102021 — identical to the kernel's restart.
 */
arm_wdt:
    mov     w1, #0
    str     w1, [x0]                 /* WTCON = 0 (disable, clear inherited arm) */
    mov     w1, #0x100
    str     w1, [x0, #0x10]          /* WTMINCNT = 0x100 — floor ABOVE WTCNT = instant
                                        windowed violation = reset in ~ms */
    mov     w1, #0x80
    str     w1, [x0, #0x08]          /* WTCNT = 0x80 */
    str     w1, [x0, #0x04]          /* WTDAT = 0x80 */
    movz    w1, #0x2021
    movk    w1, #0x10, lsl #16       /* w1 = 0x00102021 */
    str     w1, [x0]                 /* WTCON = the violation arm */
    dsb     sy
    ret
