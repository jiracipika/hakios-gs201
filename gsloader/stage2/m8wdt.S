/*
 * m8wdt — validate the WINDOWED watchdog arm at the REAL gs201 addresses
 * (0x10060000 / 0x10070000, kernel s3c2410wdt_start sequence, 16-bit WTCNT,
 * slow tick PCLK/(256*128)). 45 s window -> ~75 s band; ~29 s = arm failed
 * fast; HANG = we killed ABL's watchdog and never rearmed (power-cycle).
 */
.section .text.boot
.global _start

_start:
    msr     daifset, #0xf
    adr     x22, _start

    /* PMU counter gates: CL0 0x18061220 bit8, CL1 0x18061420 bit7 */
    movz    x10, #0x1220
    movk    x10, #0x1806, lsl #16
    ldr     w11, [x10]
    orr     w11, w11, #(1 << 8)
    str     w11, [x10]
    movz    x10, #0x1420
    movk    x10, #0x1806, lsl #16
    ldr     w11, [x10]
    orr     w11, w11, #(1 << 7)
    str     w11, [x10]
    /* PMU reset UNMASK (inverted semantics: bit2 SET = reset allowed):
       CL0 0x18061244, CL1 0x18061444 */
    movz    x10, #0x1244
    movk    x10, #0x1806, lsl #16
    ldr     w11, [x10]
    orr     w11, w11, #4
    str     w11, [x10]
    movz    x10, #0x1444
    movk    x10, #0x1806, lsl #16
    ldr     w11, [x10]
    orr     w11, w11, #4
    str     w11, [x10]
    dsb     sy

    movz    x20, #0x0000
    movk    x20, #0x1006, lsl #16          /* WDT_CL0 @ 0x10060000 */
    movz    w15, #0x83d6                   /* 750 Hz x 45 s = 33750 */
    bl      armw
    movz    x20, #0x0000
    movk    x20, #0x1007, lsl #16          /* WDT_CL1 @ 0x10070000 */
    movz    w15, #0x83d6
    bl      armw
    dsb     sy
3:  wfe
    b       3b

armw:
    ldr     w21, [x20]                     /* stop: clear ENABLE|RSTEN */
    bic     w21, w21, #0x1
    bic     w21, w21, #0x20
    str     w21, [x20]
    str     w15, [x20, #4]                 /* WTDAT = reload */
    str     w15, [x20, #8]                 /* WTCNT */
    movz    w21, #0xff39                   /* PRE255|DIV128|EN|RST (NO DBGACK:
                                              it masks the outputs when the
                                              debug-ack signal is asserted,
                                              likely high in the fastboot env) */
    str     w21, [x20]
    ret
