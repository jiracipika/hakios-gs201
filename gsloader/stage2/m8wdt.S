/*
 * m8wdt-cal — calibrate the iteration loop against wall time.
 * The 0x200c4xxx wdt's counter is frozen in this context (every countdown
 * design hangs); only the enable-time violation fires (the instant recipe,
 * proven all day). So: windowed bands = CPU-loop delay + instant reset.
 * This run: 50 rounds of 100M iterations, then the proven instant recipe.
 * Band minus ~30 s = the wall time of 50 rounds -> loop rate for all future
 * band encodings.
 */
.section .text.boot
.global _start

_start:
    msr     daifset, #0xf
    adr     x22, _start
    adr     x2, m8w_vectors
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
    sub     sp, x22, x25                 /* stack at img+0x1c40000 */

    mov     w23, #50                       /* rounds */
10: movz    x4, #0xe100
    movk    x4, #0x5f5, lsl #16            /* 100M iterations */
11: subs    x4, x4, #1
    b.ne    11b
    subs    w23, w23, #1
    b.ne    10b

    /* the SMC + PMU write from preset_recovery_mode: present before every
       arm that ever fired (m2ld v8-v11 B1 runs); absent in every hung one.
       The EL3 call may be the unlock for the whole reset path. */
    movz    x0, #0x0504
    movk    x0, #0x8200, lsl #16           /* SMC 0x82000504 */
    mov     x1, #0xff
    smc     #0
    movz    x0, #0x0810
    movk    x0, #0x1806, lsl #16           /* PMU SYSIP_DAT0 */
    movz    w1, #0x00ff
    str     w1, [x0]
    dsb     sy
1:  movz    x4, #0xe100
    movk    x4, #0x5f5, lsl #16            /* 100M iterations */
2:  subs    x4, x4, #1
    b.ne    2b
    subs    w23, w23, #1
    b.ne    1b

    /* the PROVEN instant recipe, byte-for-byte (0x102021, MINCNT 0x100,
       WTCNT 0x80, DBGACK set — this combination reset the phone all day) */
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
    movk    w21, #0xc0, lsl #16            /* key */
    str     w21, [x20, #4]
    str     wzr, [x20]
    mov     w21, #0x100
    str     w21, [x20, #16]                /* WTMINCNT (SError on bare IP:
                                              skipped by the vectors) */
    mov     w21, #0x80
    str     w21, [x20, #8]                 /* WTCNT < MINCNT */
    movz    w21, #0x2021
    movk    w21, #0x10, lsl #16            /* 0x102021 */
    str     w21, [x20]
    ret

/* minimal fault handler: count + skip (elr+4, both ELs) */
.macro VECW off
    mov     x0, #\off
    b       m8w_fault
    .space  0x78
.endm

m8w_fault:
    stp     x0, x1, [sp, #-0x20]!
    stp     x2, x3, [sp, #0x10]
    adr     x8, m8w_cnt
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
m8w_vectors:
    VECW 0x000
    VECW 0x080
    VECW 0x100
    VECW 0x180
    VECW 0x200
    VECW 0x280
    VECW 0x300
    VECW 0x380
    VECW 0x400
    VECW 0x480
    VECW 0x500
    VECW 0x580
    VECW 0x600
    VECW 0x680
    VECW 0x700
    VECW 0x780

.section .bss
.balign 64
m8w_cnt:
    .quad 0
    .quad 0
