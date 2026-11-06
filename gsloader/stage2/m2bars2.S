/*
 * m2bars2 — m2bars + the two missing display-fetch steps.
 *
 * m2bars result (user-witnessed): Google logo FROZEN for the whole run, then
 * black at the reset — code executed (executing band 4/4), bars painted into
 * 0xfac00000, but DECON never FETCHED them: the ABL-masked trigger stayed
 * effectively masked and no shadow-update was ever requested.
 *
 * Fixes per omarchy's proven recipes (cheetah flip path + panther plan):
 *   1. TRIG_CON (0x1c240030): READ-MODIFY-WRITE — clear only the
 *      HW_TRIG_MASK_DECON bit (0x10) and set HW_TRIG_EN (0x1), instead of
 *      blindly forcing cheetah's 0x3061 (panther's ABL slave bits may differ).
 *   2. DPP0 SHD_REG_UP_REQ (0x1c0b0050) = 0x8010003f — the documented
 *      flip-complete poke that latches shadowed display registers at the
 *      next frame start, making DECON actually scan 0xfac00000 again.
 * Sequence: marker → trigger fix → paint bars → shadow-update req →
 * hold ~4 s → key-wdt reset (self-recovery).
 */
.section .text
.global _start
_start:
    /* plog marker "M2b" + x0/x1 */
    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16          /* 0xfd3ff000 */
    movz    w11, #0x4244
    movk    w11, #0x4347, lsl #16          /* DBGC */
    str     w11, [x10]
    str     wzr, [x10, #4]
    movz    w11, #32
    str     w11, [x10, #8]
    movz    w11, #0x326d                   /* 'm','2' */
    movk    w11, #0x0a62, lsl #16          /* 'b','\n' -> "m2b\n" */
    str     w11, [x10, #12]
    str     x0, [x10, #16]
    str     x1, [x10, #24]
    dsb     sy

    /* TRIG_CON = (old & ~0x10) | 1 */
    movz    x9, #0x0030
    movk    x9, #0x1c24, lsl #16           /* 0x1c240030 */
    ldr     w8, [x9]
    bic     w8, w8, #0x10
    orr     w8, w8, #1
    str     w8, [x9]
    dsb     sy

    /* paint bars: fb 0xfac00000, 1080x2400 XRGB */
    movz    x7, #0x0000
    movk    x7, #0xfac0, lsl #16
    mov     x6, xzr
row:
    cmp     x6, #800
    b.lt    red
    cmp     x6, #1600
    b.lt    green
    movz    w5, #0x00ff
    movk    w5, #0xff00, lsl #16           /* blue */
    b       store
red:
    movz    w5, #0x0000
    movk    w5, #0xffff, lsl #16           /* red */
    b       store
green:
    movz    w5, #0xff00
    movk    w5, #0x00ff, lsl #16           /* green */
store:
    mov     x4, xzr
col:
    str     w5, [x7], #4
    add     x4, x4, #1
    cmp     x4, #1080
    b.lt    col
    add     x6, x6, #1
    cmp     x6, #2400
    b.lt    row
    dsb     sy

    /* DPP0 SHD_REG_UP_REQ = 0x8010003f (the flip poke) */
    movz    x9, #0x0050
    movk    x9, #0x1c0b, lsl #16           /* 0x1c0b0050 */
    movz    w8, #0x003f
    movk    w8, #0x8010, lsl #16
    str     w8, [x9]
    dsb     sy

    /* hold ~4 s */
    mov     w20, #6
1:  movz    x21, #0xe100
    movk    x21, #0x5f5, lsl #16
2:  subs    x21, x21, #1
    b.ne    2b
    subs    w20, w20, #1
    b.ne    1b

    /* key-wdt reset, both clusters */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      arm
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      arm
    dsb     sy
3:  wfe
    b       3b

arm:
    movz    w21, #0xffee
    movk    w21, #0xc0, lsl #16            /* 0xc0ffee */
    str     w21, [x20, #4]
    str     wzr, [x20]
    mov     w21, #0x100
    str     w21, [x20, #16]
    mov     w21, #0x80
    str     w21, [x20, #8]
    movz    w21, #0x2021
    movk    w21, #0x10, lsl #16
    str     w21, [x20]
    ret
