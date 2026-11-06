/*
 * pe_mmutoff — solo test of the MMU-off preamble on the PE vehicle.
 *
 * m2blink2 floored at 104s, but its DSIM access explains that on its own; the
 * SCTLR-zeroing preamble has never run alone. The M2 loader WANTS MMU off at
 * entry (mtkloader's proven environment; segment copies to 0x880000000+ must
 * not depend on ABL's map covering the high banks). This test: CurrentEL ->
 * SCTLR_EL2/EL1 zero -> ic iallu -> marker "MMU" + x0/x1 to ramoops ->
 * key-wdt arm -> park. Identity-mapped (VA==PA) = nothing changes for fetch:
 * ~30s band. Non-identity = next fetch dies: 104s floor. Either way we learn
 * the ground truth the M2 loader's safety depends on.
 */
.section .text
.global _start
_start:
    mov     x25, x0
    mov     x26, x1
    mrs     x1, CurrentEL
    lsr     x1, x1, #2
    cmp     x1, #2
    b.ne    11f
    msr     sctlr_el2, xzr
11: msr     sctlr_el1, xzr
    isb
    ic      iallu
    dsb     sy
    isb

    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16          /* 0xfd3ff000 */
    movz    w11, #0x4244
    movk    w11, #0x4347, lsl #16          /* DBGC */
    str     w11, [x10]
    str     wzr, [x10, #4]
    movz    w11, #32
    str     w11, [x10, #8]
    movz    w11, #0x4d4d                   /* 'M','M' */
    movk    w11, #0x0a55, lsl #16          /* 'U','\n' = "MMU\n" */
    str     w11, [x10, #12]
    str     x25, [x10, #16]
    str     x26, [x10, #24]
    dsb     sy

    /* small delay so the outcome can't be confused with an instant arm */
    mov     w20, #6
1:  movz    x21, #0xe100
    movk    x21, #0x5f5, lsl #16
2:  subs    x21, x21, #1
    b.ne    2b
    subs    w20, w20, #1
    b.ne    1b

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
