/*
 * m8wdt-d — countdown test on the EMPIRICAL watchdog (0x200c4000),
 * SMALL vehicle (the only one that executes).
 *
 * The "counter frozen" conclusion is void: those tests ran on the big
 * vehicle (never executed). rdscan proved the INSTANT arm fires here
 * (29 s with no SMC). If the COUNTDOWN also works, arm count=0xFFFF at
 * the slow tick (PRE255|DIV128 ~ 750 Hz) = ~87 s -> band ~112 s
 * (25 s Android + 87 s). If the counter is truly frozen: the violation
 * check at enable time still sees count(0xFFFF) >= MINCNT(0x100) -> NO
 * violation -> nothing fires -> hang (power button).
 */
.section .text.boot
.global _start

_start:
    msr     daifset, #0xf
    adr     x22, _start

    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      armc
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      armc
    dsb     sy
3:  wfe
    b       3b

armc:
    movz    w21, #0xffee                   /* key */
    movk    w21, #0xc0, lsl #16
    str     w21, [x20, #4]
    str     wzr, [x20]                     /* stop */
    movz    w21, #0x0100
    str     w21, [x20, #16]                /* WTMINCNT */
    movz    w15, #0xffff                   /* max count */
    str     w15, [x20, #4]                 /* WTDAT */
    str     w15, [x20, #8]                 /* WTCNT */
    movz    w21, #0xff39                   /* PRE255|DIV128|EN|RST */
    str     w21, [x20]
    ret
