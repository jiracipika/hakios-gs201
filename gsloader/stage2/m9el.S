/*
 * m9el — what exception level does ABL enter us at? (band-encoded, small
 * vehicle). EL2 -> +8 s before the proven instant arm (38 s band);
 * EL1 -> +0 s (30 s band). Decides whether the m2ld_jump eret-to-EL1 is
 * switching into an unmapped translation regime (the v15 hang theory).
 */
.section .text.boot
.global _start

_start:
    msr     daifset, #0xf
    adr     x22, _start
    adr     x2, m9_vectors
    mrs     x20, CurrentEL
    lsr     x20, x20, #2
    cmp     x20, #2
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

    mrs     x21, CurrentEL
    lsr     x21, x21, #2                  /* x21 = 1 (EL1) or 2 (EL2) */
    /* settle delay FIRST (~2 s, 50 rounds) — the wdt arm only fires when
       there is >= ~1 s of pre-arm activity after ABL handoff (rdscan
       fired; every arm-immediately blob hung) */
    mov     w23, #50
11: movz    x4, #0xe100
    movk    x4, #0x5f5, lsl #16
12: subs    x4, x4, #1
    b.ne    12b
    subs    w23, w23, #1
    b.ne    11b
    cmp     x21, #2
    b.ne    10f
    /* EL2: +8 s more (200 rounds) */
    mov     w23, #200
13: movz    x4, #0xe100
    movk    x4, #0x5f5, lsl #16
14: subs    x4, x4, #1
    b.ne    14b
    subs    w23, w23, #1
    b.ne    13b
10:
    /* proven instant arm, both empirical watchdogs */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      armi
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      armi
    dsb     sy
3:  wfe
    b       3b

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

/* minimal fault handler: count + skip (elr+4, both ELs) — ESSENTIAL: the
   wdt/MMIO stores raise synchronous external aborts on partially-mapped
   regions; without these the first faulting store jumps to a garbage VBAR
   and the whole blob hangs (the m8wdt-d/m9el-v1 lesson) */
.macro VEC9 off
    mov     x0, #\off
    b       m9_fault
    .space  0x78
.endm

m9_fault:
    stp     x0, x1, [sp, #-0x20]!
    stp     x2, x3, [sp, #0x10]
    adr     x8, m9_cnt
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
m9_vectors:
    VEC9 0x000
    VEC9 0x080
    VEC9 0x100
    VEC9 0x180
    VEC9 0x200
    VEC9 0x280
    VEC9 0x300
    VEC9 0x380
    VEC9 0x400
    VEC9 0x480
    VEC9 0x500
    VEC9 0x580
    VEC9 0x600
    VEC9 0x680
    VEC9 0x700
    VEC9 0x780

.section .bss
.balign 64
m9_cnt:
    .quad 0
    .quad 0
