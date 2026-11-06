/*
 * m7a / m7b — one-piece preamble bisect on top of the proven v13 flow.
 *   m7a (-DM7=0): v13 + vbar install ONLY (no spsel, no sp)
 *   m7b (-DM7=1): v13 + spsel + in-image sp ONLY (no vbar)
 * Both end in the proven instant key-wdt arm -> 30 s band expected; 105 s
 * means the added piece is the killer.
 */
.section .text.boot
.global _start

#ifndef M7
#define M7 0
#endif

_start:
    msr     daifset, #0xf

.if M7 == 0
    adr     x2, m7_vectors
    mrs     x21, CurrentEL
    lsr     x21, x21, #2
    cmp     x21, #2
    b.eq    1f
    msr     vbar_el1, x2
    b       2f
1:  msr     vbar_el2, x2
    msr     vbar_el1, x2
2:  isb
.else
    adr     x22, _start
    msr     spsel, #1
    movz    x25, #0xa458
    movk    x25, #0x000e, lsl #16
    sub     sp, x22, x25
.endif

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

/* for m7a: a table of eret-returns (harmless if ever entered) */
.macro VEC7 off
    b       7f
    .space  0x7c
7:  eret
.endm

    .balign 0x80
    .space 0x28
m7_vectors:
    VEC7 0x000
    VEC7 0x080
    VEC7 0x100
    VEC7 0x180
    VEC7 0x200
    VEC7 0x280
    VEC7 0x300
    VEC7 0x380
    VEC7 0x400
    VEC7 0x480
    VEC7 0x500
    VEC7 0x580
    VEC7 0x600
    VEC7 0x680
    VEC7 0x700
    VEC7 0x780
