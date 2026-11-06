/*
 * m2bars — the M2 gate, observable with human eyes.
 *
 * Vehicle (proven by v12/v13): stock-shaped kernel image, stock PE headers
 * verbatim, our code at the stock AddressOfEntryPoint RVA (0x1d2a458). ABL
 * enters here; x0/x1 are whatever it passes (marker'd to the ramoops zone).
 *
 * Observable: the ABL splash framebuffer (0xfac00000, 1080x2400, XRGB8888,
 * stride 4320 — omarchy/Linaro-verified facts) is frozen because the
 * bootloader masks DECON0's hardware trigger on handoff. Writing
 * TRIG_CON (0x1c240030) = 0x3061 re-enables it; stores to the framebuffer
 * then hit the panel on the next TE. We paint three giant color bars, hold
 * ~4 s, then reset via the key-locked cluster watchdogs (proven 2/2) so the
 * phone returns to Android by itself — no finger, no root, no UART.
 *
 * If you see RED/GREEN/BLUE bars after `fastboot boot`: entry, execution,
 * MMIO, the DECON trick, framebuffer writes, and the reset path are ALL
 * proven in one shot — and the console for the whole port is born.
 */
.section .text
.global _start
_start:
    /* 1. plog marker + ABL's x0/x1 into the ramoops console zone */
    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16          /* 0xfd3ff000 */
    movz    w11, #0x4244
    movk    w11, #0x4347, lsl #16          /* DBGC */
    str     w11, [x10]
    str     wzr, [x10, #4]
    movz    w11, #32
    str     w11, [x10, #8]
    movz    w11, #0x324d                   /* 'M','2' */
    movk    w11, #0x000a, lsl #16          /* 'M','2','\n',0 = 0x000A324D */
    str     w11, [x10, #12]
    str     x0, [x10, #16]
    str     x1, [x10, #24]
    dsb     sy

    /* 2. re-enable the DECON hardware trigger: TRIG_CON = 0x3061 */
    movz    x9, #0x0030
    movk    x9, #0x1c24, lsl #16           /* 0x1c240030 */
    movz    w8, #0x3061
    str     w8, [x9]
    dsb     sy

    /* 3. paint the bars: fb 0xfac00000, 1080x2400, XRGB (A<<24|B<<16|G<<8|R)
       rows   0-799  = red   0xFFFF0000
       rows 800-1599 = green 0xFF00FF00
       rows 1600-2399= blue  0xFF0000FF  */
    movz    x7, #0x0000
    movk    x7, #0xfac0, lsl #16           /* x7 = fb base */
    mov     x6, xzr                       /* row */
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
    mov     x4, xzr                       /* col (pixels) */
col:
    str     w5, [x7], #4
    add     x4, x4, #1
    cmp     x4, #1080
    b.lt    col
    add     x6, x6, #1
    cmp     x6, #2400
    b.lt    row
    dsb     sy

    /* 4. hold ~4 s so a human sees it (48 rounds ~= 20-40 s measured on v1) */
    mov     w20, #6
1:  movz    x21, #0xe100
    movk    x21, #0x5f5, lsl #16           /* 100,000,000 */
2:  subs    x21, x21, #1
    b.ne    2b
    subs    w20, w20, #1
    b.ne    1b

    /* 5. reset via the key-locked cluster watchdogs (proven 2/2) */
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
    movk    w21, #0xc0, lsl #16            /* 0xc0ffee KEY */
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
