/*
 * m8rd — where does ABL put the ramdisk? A band-encoded scanner.
 *
 * Boots on the bare+ramdisk vehicle, sweeps DRAM at 4 KiB steps for the
 * lz4-legacy magic (0x184C2102) and the raw-GSPE magic (0x45505347), then
 * delays before an instant key-wdt reset:
 *
 *   first lz4 hit at 0xNNxxxxxx  ->  (NN - 0x80) * 4 seconds
 *   first lz4 hit in high bank   ->  70 + (a>>28 - 0x88) * 4 seconds (cap 90)
 *   no lz4 anywhere, GSPE hit(s) ->  +1 s per GSPE hit (base 30 s)
 *   nothing found anywhere       ->  flat 30 s
 *
 * All under fault-recovering skip-vectors; iteration-loop delays (CNTPCT is
 * trapped in this environment).
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

    mov     w19, #0                 /* delay seconds accumulator */
    movz    w17, #0x02
    movk    w17, #0x2102, lsl #16   /* lz4 legacy magic LE */
    movz    w18, #0x5347
    movk    w18, #0x4550, lsl #16   /* "GSPE" LE */

    /* CONTROL + BASE REPORT: imgbase = self - AEP. The header word there
       must equal 0xfa405a4d (we execute from this region) -> +3 s, and the
       band ALSO encodes the image base: += ((imgbase>>24) & 0x3f) seconds.
       M8RD4's flat 29 s proved the base is NOT 0x80000000 — the load
       address moves with the image variant, so everything downstream must
       be self-relative. */
    movz    x5, #0xa458
    movk    x5, #0x1d2a, lsl #16
    sub     x0, x22, x5              /* x0 = imgbase = self - 0x1d2a458 */
    adr     x8, m8_cnt
    ldr     x7, [x8]
    movz    w16, #0xa5a5
    movk    w16, #0xa5a5, lsl #16
    ldr     w16, [x0]
    dsb     sy
    adr     x8, m8_cnt
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne    60f
    movz    w15, #0x5a4d
    movk    w15, #0xfa40, lsl #16
    cmp     w16, w15
    b.ne    60f
    add     w19, w19, #3
    lsr     x9, x0, #24
    and     x9, x9, #0x3f
    cmp     x9, #40
    bhi     60f
    add     w19, w19, w9
60:

    /* ---- scan low bank [0x82300000, 0xe8000000) ---- */
    movz    x0, #0x0000
    movk    x0, #0x8230, lsl #16
10: movz    x1, #0x0000
    movk    x1, #0xe800, lsl #16
    b       20f
11: add     x0, x0, #0x1000
20: cmp     x0, x1
    b.hs    30f
    adr     x8, m8_cnt
    ldr     x7, [x8]
    movz    w16, #0xa5a5
    movk    w16, #0xa5a5, lsl #16
    ldr     w16, [x0]
    dsb     sy
    adr     x8, m8_cnt
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne    11b                     /* faulted: unmapped page, move on */
    cmp     w16, w17
    b.ne    25f
    /* lz4 hit: delay = ((a>>24) - 0x80) * 4 */
    lsr     x9, x0, #24
    and     x9, x9, #0xff
    sub     x9, x9, #0x80
    cmp     x9, #1
    blo     26f
    cmp     x9, #15
    bhi     26f
    lsl     x9, x9, #2
    mov     w19, w9
    b       40f
25: cmp     w16, w18
    b.ne    11b
    add     w19, w19, #1            /* GSPE hit: +1 s each */
    b       11b
26: mov     w19, #4                 /* lz4 somewhere odd: 4 s marker */
    b       40f
30: /* low done — scan the REST: [0x880000000, 0x280000000) (DRAM top for
       the 8 GB phone). First hit of any type encodes:
       delay = ((a>>28) - 0x88) + bonus (lz4 +0, GSPE +1, ANDROID! +2),
       cap 80 s. */
    movz    x0, #0x0000
    movk    x0, #0x0000, lsl #16
    movk    x0, #0x8800, lsl #32
31: movz    x1, #0x0000
    movk    x1, #0x0000, lsl #16
    movk    x1, #0x2800, lsl #32
    movz    w23, #0x4e41
    movk    w23, #0x5244, lsl #16   /* "ANDR" LE */
    b       33f
32: add     x0, x0, #0x1000
33: cmp     x0, x1
    b.hs    40f
    adr     x8, m8_cnt
    ldr     x7, [x8]
    movz    w16, #0xa5a5
    movk    w16, #0xa5a5, lsl #16
    ldr     w16, [x0]
    dsb     sy
    adr     x8, m8_cnt
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne     32b                    /* faulted: skip page */
    mov     w10, #0                 /* bonus 0: lz4 */
    cmp     w16, w17
    b.eq    37f
    mov     w10, #1                 /* bonus 1: GSPE */
    cmp     w16, w18
    b.eq    37f
    mov     w10, #2                 /* bonus 2: ANDROID! */
    cmp     w16, w23
    b.ne    32b
37: lsr     x9, x0, #28
    sub     x9, x9, #0x88
    cmp     x9, #0
    blo     32b
    cmp     x9, #60
    bhi     32b
    add     x9, x9, x10             /* + bonus */
    cmp     x9, #80
    blo     34f
    mov     x9, #80
34: mov     w19, w9
    b       40f

40: /* delay w19 TRUE seconds via the watchdog down-counter (46545 Hz;
       the iteration loops were ~10x fast — every earlier m8rd band was
       compressed into noise). Count-only (no RSTEN), poll to zero, stop. */
    uxtw    x3, w19
    cbz     x3, 50f
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16    /* WDT_CL0 */
    movz    w14, #0xffee
    movk    w14, #0xc0, lsl #16      /* KEY */
    str     w14, [x20, #4]
    str     wzr, [x20]               /* stop */
    mov     w14, #0x100
    str     w14, [x20, #16]          /* WTMINCNT floor */
    mov     x4, #46545
    mul     x4, x4, x3               /* ticks = seconds * 46545 */
    cmp     x4, #0x40000000
    blo     45f
    movz    x4, #0x0000
    movk    x4, #0x4000, lsl #16     /* cap 32-bit */
45: str     w4, [x20, #8]            /* WTCNT */
    movz    w14, #0x2020
    movk    w14, #0x10, lsl #16      /* count-only: DBGACK|PRESCALE|ENABLE */
    str     w14, [x20]
46: ldr     w14, [x20, #8]
    cmp     w14, #0x100
    b.hi    46b
    movz    w14, #0xffee
    movk    w14, #0xc0, lsl #16
    str     w14, [x20, #4]
    str     wzr, [x20]               /* stop */

50: movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      arm
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      arm
    dsb     sy
51: wfe
    b       51b

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
