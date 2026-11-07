/*
 * m8rd-v4 — self-relative ramdisk locator (small vehicle, proven running).
 *
 * The gate is real: stock content + <=64KB patch executes; bigger content
 * mods floor. So the XNU payload must arrive via the boot image's ramdisk
 * field — and the only unknown is WHERE ABL puts it. Yesterday's absolute
 * scans (0x82300000-0xE8000000, 0x880000000-0x280000000) found nothing, but
 * never covered the neighborhood of the image itself (imgbase unknown —
 * the 0x80000000 control failed, so bare images load elsewhere).
 *
 * This scanner runs AT the entry (self = imgbase + 0x1d2a458) and sweeps:
 *   UP   [self+0x1d30000, self+0x8000000)  4KB steps  -> GSPE hit: +8 s
 *   DOWN [self-0x1000000, self)            4KB steps  -> GSPE hit: +16 s
 * plus the proven instant arm at the end. Bands: 30 none / 38 above /
 * 46 below / 54 both (noise +-3 s).
 * Ship with the GSPE ramdisk RAW so the magic is plain in DRAM.
 */
.section .text.boot
.global _start

_start:
    msr     daifset, #0xf
    adr     x22, _start
    adr     x2, m8_vectors
    mrs     x21, CurrentEL
    lsr     x21, x21, #2
    cmp     x21, #2
    b.eq    1f
    msr     vbar_el1, x2
    b       2f
1:  msr     vbar_el2, x2
    msr     vbar_el1, x2
2:  isb
    msr     spsel, #1
    movz    x25, #0xa458
    movk    x25, #0x000e, lsl #16
    sub     sp, x22, x25

    mov     w19, #0                 /* delay seconds */
    movz    w18, #0x5347
    movk    w18, #0x4550, lsl #16   /* "GSPE" LE */

    /* UP scan: self+0x1d30000 .. self+0x8000000 */
    movz    x0, #0x0000
    movk    x0, #0x01d3, lsl #16    /* 0x1d30000 */
    add     x0, x22, x0
    movz    x1, #0x0000
    movk    x1, #0x0080, lsl #16    /* 0x8000000 */
    add     x1, x22, x1
10: cmp     x0, x1
    b.hs    20f
    adr     x8, m8_cnt
    ldr     x7, [x8]
    movz    w16, #0xa5a5
    movk    w16, #0xa5a5, lsl #16
    ldr     w16, [x0]
    dsb     sy
    adr     x8, m8_cnt
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne    11f
    cmp     w16, w18
    b.eq    15f
11: add     x0, x0, #0x1000
    b       10b
15: add     w19, w19, #8
    b       20f

    /* DOWN scan: self-0x1000000 .. self-0x1000 */
20: movz    x0, #0x0000
    movk    x0, #0x0100, lsl #16    /* 0x1000000 */
    sub     x0, x22, x0
21: adr     x8, m8_cnt
    ldr     x7, [x8]
    movz    w16, #0xa5a5
    movk    w16, #0xa5a5, lsl #16
    ldr     w16, [x0]
    dsb     sy
    adr     x8, m8_cnt
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne    22f
    cmp     w16, w18
    b.eq    25f
22: add     x0, x0, #0x1000
    cmp     x0, x22
    b.lo    21b
25: add     w19, w19, #16

30: /* delay w19 seconds (~40 ms per 100M-round; coarse but band-separated) */
    uxtw    x3, w19
    cbz     x3, 40f
31: movz    x4, #0xe100
    movk    x4, #0x5f5, lsl #16
32: subs    x4, x4, #1
    b.ne    32b
    subs    x3, x3, #1
    b.ne    31b

40: /* the PROVEN instant recipe (0x102021, MINCNT 0x100, WTCNT 0x80) */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      armi
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      armi
    dsb     sy
41: wfe
    b       41b

armi:
    movz    w21, #0xffee
    movk    w21, #0xc0, lsl #16
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

.macro VEC8 off
    mov     x0, #\off
    b       m8_fault
    .space  0x78
.endm

m8_fault:
    stp     x0, x1, [sp, #-0x20]!
    stp     x2, x3, [sp, #0x10]
    adr     x8, m8_cnt
    ldr     x9, [x8]
    add     x9, x9, #1
    str     x9, [x8]
    mrs     x3, CurrentEL
    lsr     x3, x3, #2
    cmp     x3, #2
    b.eq    43f
    mrs     x2, elr_el1
    add     x2, x2, #4
    msr     elr_el1, x2
    b       44f
43: mrs     x2, elr_el2
    add     x2, x2, #4
    msr     elr_el2, x2
44: ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp], #0x20
    eret

    .balign 0x80
    .space 0x28
m8_vectors:
    VEC8 0x000
    VEC8 0x080
    VEC8 0x100
    VEC8 0x180
    VEC8 0x200
    VEC8 0x280
    VEC8 0x300
    VEC8 0x380
    VEC8 0x400
    VEC8 0x480
    VEC8 0x500
    VEC8 0x580
    VEC8 0x600
    VEC8 0x680
    VEC8 0x700
    VEC8 0x780

.section .bss
.balign 64
m8_cnt:
    .quad 0
    .quad 0
