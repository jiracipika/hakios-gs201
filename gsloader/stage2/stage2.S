/*
 * stage2 — the M1 payload proof (Pixel 7 / gs201), v2.
 *
 * Silicon evidence (M1 v1, 2026-11-06): ABL ran the loader->payload chain far
 * enough to park, and the phone self-recovered via its hardware watchdog
 * (bootreason "watchdog,apc,early"). But PSCI SYSTEM_RESET silently no-ops in
 * the ABL fastboot-boot context (both SMC and HVC returned without effect),
 * so the reset is now the kernel's own emergency-restart recipe
 * (s3c2410wdt_restart(), gs kernel drivers/watchdog/s3c2410_wdt.c): program
 * BOTH cluster watchdogs (cl0 @0x200c4000, cl1 @0x200c5000) for an instant
 * windowed-watchdog violation (WTCNT 0x80 < WTMINCNT 0x100) -> hard reset in
 * milliseconds. No EL2, no ATF, no PMU registers, no key registers.
 *
 * Observable outcome: fastboot boot -> ~6-10s busy delay -> hard reset ->
 * Android -> adb returns ~45-70s. If adb instead returns at ~150-165s, the
 * payload jump is broken (loader error-parked; the ABL-armed watchdog then
 * fired at its full ~111s expiry — indistinguishable dump, distinguishable
 * only by round-trip time).
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

    /* ~6-10s busy delay (12 rounds x 100M iters; M1 v1 measured 48 rounds at
       20-40s). Any value far from 0 and far from ~111s discriminates the two
       failure modes by round-trip time alone. */
    mov     w20, #12
1:  movz    x21, #0xe100
    movk    x21, #0x5f5, lsl #16     /* x21 = 100,000,000 */
2:  subs    x21, x21, #1
    b.ne    2b
    subs    w20, w20, #1
    b.ne    1b

    /* s3c2410wdt_restart() verbatim on both cluster watchdogs */
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
