/*
 * stage2 — the M1 payload proof (Pixel 7 / gs201), v4 (KEY protocol).
 *
 * Silicon evidence (2026-11-06 night): six runs with byte-identical outcomes
 * (104s ABL-watchdog comeback, bootreason watchdog,apc,early) across PSCI /
 * delay+arm / MMU-off+arm payload variants — our wdt writes were silently
 * ignored every time. Root cause found in the ABL binary + vendor_boot DTB:
 * the gs201 cluster watchdog blocks are KEY-LOCKED. KEY register at block
 * base +0x04: write 0xc0ffee to unlock, 0x0 to lock. The kernel's
 * s3c2410wdt_restart recipe writes WTDAT at +0x04 — i.e. a garbage key to a
 * locked block — so its arm never took effect. v4 unlocks first (see
 * arm_wdt below), then arms the instant windowed violation.
 *
 * MMU/caches are still turned off by our own hand first (EL2-aware).
 *
 * GREEN = adb back in ~45-55s (reset in ~ms after payload entry).
 * 104s again = the payload branch still never reaches the writes (entry/jump
 * path bug — then the next diagnostic is ABL's own bl_old_log, readable from
 * a root shell at 0xfd880000).
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
 * arm_wdt — gs201 cluster-watchdog arm for one block, with the KEY protocol.
 * x0 = block base (cl0 0x200c4000, cl1 0x200c5000).
 *
 * ABL binary disassembly (bootloader-rango, Thumb fn @0xf90ffc): KEY register
 * lives at block base +0x04 — write 0xc0ffee to UNLOCK, 0x0 to LOCK — and the
 * ABL descriptor tables carry {0x200c4000/-1/0xc0ffee} and {0x200c5000/-1/
 * 0xc0ffee}. The vendor_boot DTB says the same: watchdog_cl0/cl1 have
 * key-unlock=<0xc0ffee>, key-lock=<0x0>. On gs201 the +0x04 slot REPLACES the
 * classic s3c WTDAT — which means the kernel's s3c2410wdt_restart recipe
 * (WTDAT write at +0x04) writes a garbage key to a locked block and every
 * subsequent write is silently ignored. That is exactly what v2/v3/v6 did.
 * WTDAT is therefore skipped entirely: the instant windowed violation comes
 * from WTMINCNT (0x100) > WTCNT (0x80), which needs no WTDAT.
 *
 * WTCON value: ENABLE(bit5) | RSTEN(bit0) | DIV16 | PRESCALE(0x20)<<8 |
 *              WINDOWED(bit20) = 0x102021.
 */
arm_wdt:
    movz    w1, #0xffee
    movk    w1, #0xc0, lsl #16       /* w1 = 0x00c0ffee */
    str     w1, [x0, #0x04]          /* KEY = unlock */
    mov     w1, #0
    str     w1, [x0]                 /* WTCON = 0 (disable, clear inherited arm) */
    mov     w1, #0x100
    str     w1, [x0, #0x10]          /* WTMINCNT = 0x100 — floor ABOVE WTCNT = instant
                                        windowed violation = reset in ~ms */
    mov     w1, #0x80
    str     w1, [x0, #0x08]          /* WTCNT = 0x80 */
    movz    w1, #0x2021
    movk    w1, #0x10, lsl #16       /* w1 = 0x00102021 */
    str     w1, [x0]                 /* WTCON = the violation arm */
    dsb     sy
    ret
