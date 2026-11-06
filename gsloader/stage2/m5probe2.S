/*
 * m5probe — timing-encoded memory map probe on the PE vehicle (Pixel 7).
 *
 * After the 97-106 s "silent" bands, everything now hinges on one fact:
 * which addresses ABL's fastboot-boot environment actually maps. This image
 * answers it eyes-free: load-probes under fault-recovering vectors, then a
 * superincreasing per-address delay before an instant key-wdt reset. Band
 * = ~30 s + sum(8/16/32/64 s for each mapped address) — unique decode.
 *
 * Build twice:  clang --defsym GRP=0  -> group A (ramoops/bl regions)
 *               clang --defsym GRP=1  -> group B (fb + DRAM windows)
 *   A: 0xfd3ff000 +8s  0xfd5ff000 +16s  0xfd800000 +32s  0xfd880000 +64s
 *   B: 0xfac00000 +8s  0x84000000 +16s  0x86000000 +32s  0x880000000 +64s
 */
.section .text.boot
.global _start

#ifndef GRP
#define GRP 0
#endif

#define STACK_TOP_OFF 0x1c40000

_start:
    msr     daifset, #0xf
    adr     x22, _start
    adr     x2, m5_vectors
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
    movz    x25, #0x0000
    movk    x25, #0x1c4, lsl #16
    add     sp, x22, x25

    mov     w20, #0                     /* accumulated delay seconds */

    /* PROBEW <hi32-part> <lo> <seconds-weight> — credit if the ldr faults not */
    .macro PROBEW hi, lo, w
    adr     x8, m5_faults
    ldr     x7, [x8]
    movz    w1, #0xa5a5
    movk    w1, #0xa5a5, lsl #16
    movz    x0, #\lo
    movk    x0, #\hi, lsl #16
    ldr     w1, [x0]
    dsb     sy
    adr     x8, m5_faults
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne    90f
    mov     w10, #\w
    add     w20, w20, w10
90:
    .endm

.if GRP == 0
    PROBEW 0xfd3f, 0xf000, 64           /* console zone    +64 s */
    PROBEW 0xfd5f, 0xf000, 128          /* pmsg zone       +128 s */
    PROBEW 0xfd80, 0x0000, 32           /* bl_log          +32 s */
    
.else
    PROBEW 0xfac0, 0x0000, 8            /* framebuffer     +8 s  */
    PROBEW 0x8400, 0x0000, 16           /* DRAM 0x84000000 +16 s */
    PROBEW 0x8600, 0x0000, 32           /* DRAM 0x86000000 +32 s */
.endif

    /* group B's 4th: 0x880000000 (full 64-bit immediate) */
.if GRP != 0
    adr     x8, m5_faults
    ldr     x7, [x8]
    movz    w1, #0xa5a5
    movk    w1, #0xa5a5, lsl #16
    movz    x0, #0x0000
    movk    x0, #0x8000, lsl #16
    movk    x0, #0x0008, lsl #32         /* 0x0000000880000000 */
    ldr     w1, [x0]
    dsb     sy
    adr     x8, m5_faults
    ldr     x6, [x8]
    cmp     x6, x7
    b.ne    91f
    mov     w10, #64
    add     w20, w20, w10
91:
.endif

    /* delay = w20 seconds via the generic timer */
    mrs     x2, cntfrq_el0
    uxtw    x3, w20
    mul     x3, x3, x2
    isb
    mrs     x4, cntpct_el0
    add     x4, x4, x3
92: mrs     x5, cntpct_el0
    cmp     x5, x4
    b.lo    92b

    /* instant key-wdt reset, both clusters */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      arm
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      arm
    dsb     sy
93: wfe
    b       93b

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

/* fault handler: count, skip (elr+4 on sync slots) */
.macro VEC off
    mov     x0, #\off
    b       m5_fault_common
    .space  0x74
.endm

m5_fault_common:
    stp     x0, x1, [sp, #-0x20]!
    stp     x2, x3, [sp, #0x10]
    adr     x8, m5_faults
    ldr     x9, [x8]
    add     x9, x9, #1
    str     x9, [x8]
    ldr     x0, [sp]
    tst     x0, #0x1ff
    b.ne    94f
    mrs     x3, CurrentEL
    lsr     x3, x3, #2
    cmp     x3, #2
    b.eq    95f
    mrs     x2, elr_el1
    add     x2, x2, #4
    msr     elr_el1, x2
    b       94f
95: mrs     x2, elr_el2
    add     x2, x2, #4
    msr     elr_el2, x2
94: ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp], #0x20
    eret

    /* runtime 0x80-alignment pad (AEP is 0x58 mod 0x80) */
    .balign 0x80
    .space 0x28
m5_vectors:
    VEC 0x000
    VEC 0x080
    VEC 0x100
    VEC 0x180
    VEC 0x200
    VEC 0x280
    VEC 0x300
    VEC 0x380
    VEC 0x400
    VEC 0x480
    VEC 0x500
    VEC 0x580
    VEC 0x600
    VEC 0x680
    VEC 0x700
    VEC 0x780

.section .bss
.balign 64
m5_faults:
    .quad 0
    .quad 0
