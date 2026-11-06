/*
 * m6base / m6vec — preamble isolation on the PE vehicle.
 *
 * m6base: full m2ld preamble (vbar both ELs, spsel, in-image stack) then an
 *         instant key-wdt arm.  ~30 s band expected.
 * m6vec:  the same, but one deliberate load from address 0 before the arm —
 *         reaching the arm at all proves the skip-vectors recover a sync
 *         abort (the piece every hang today might be breaking).
 * Build with -DVEC=1 for the fault variant.
 */
.section .text.boot
.global _start

#ifndef M6VEC
#define M6VEC 0
#endif

_start:
    msr     daifset, #0xf
    adr     x22, _start
    adr     x2, m6_vectors
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
    movk    x25, #0x000e, lsl #16          /* 0xea458 */
    sub     sp, x22, x25                  /* sp = img + 0x1c40000 */

.if M6VEC
    mov     x1, xzr
    ldr     x0, [x1]                       /* deliberate sync abort */
    dsb     sy
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

/* minimal fault handler: count + skip (elr+4, both EL variants) */
.macro VEC6 off
    mov     x0, #\off
    b       m6_fault
    .space  0x78
.endm

m6_fault:
    stp     x0, x1, [sp, #-0x20]!
    stp     x2, x3, [sp, #0x10]
    adr     x8, m6_cnt
    ldr     x9, [x8]
    add     x9, x9, #1
    str     x9, [x8]
    mrs     x3, CurrentEL
    lsr     x3, x3, #2
    cmp     x3, #2
    b.eq    4f
    mrs     x2, elr_el1
    add     x2, x2, #4
    msr     elr_el1, x2
    b       5f
4:  mrs     x2, elr_el2
    add     x2, x2, #4
    msr     elr_el2, x2
5:  ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp], #0x20
    eret

    /* runtime 0x80-alignment pad (AEP is 0x58 mod 0x80) */
    .balign 0x80
    .space 0x28
m6_vectors:
    VEC6 0x000
    VEC6 0x080
    VEC6 0x100
    VEC6 0x180
    VEC6 0x200
    VEC6 0x280
    VEC6 0x300
    VEC6 0x380
    VEC6 0x400
    VEC6 0x480
    VEC6 0x500
    VEC6 0x580
    VEC6 0x600
    VEC6 0x680
    VEC6 0x700
    VEC6 0x780

.section .bss
.balign 64
m6_cnt:
    .quad 0
