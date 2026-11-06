/*
 * m2ld.S — M2 loader entry for the PE vehicle (Pixel 7 / gs201).
 *
 * ABL enters the stock-shaped kernel image at its PE AddressOfEntryPoint
 * (image+0x1d2a458) with ABL's MMU on and x0/x1 whatever ABL passes (logged).
 * Silicon-proven facts this is built on: MMU-off at entry is fatal, so the
 * loader runs entirely under ABL's identity map and never touches SCTLR; the
 * key-locked cluster watchdogs (0xc0ffee at +0x04) give deterministic resets.
 *
 * Fault recovery: our own VBAR with skip-handlers — a synchronous abort records
 * ESR/ELR/FAR into m2_fault_log and advances ELR by 4, so a probe load from an
 * unmapped address is survivable and detectable (register keeps its sentinel,
 * fault count rises) instead of a blind 104s park.
 *
 * The jump to XNU keeps the MMU on (identity assumed — everything proven
 * mapped so far is identity) and normalizes EL2 -> EL1h exactly like
 * mtkloader's silicon-proven trampoline, minus its SCTLR clearing.
 */
.section .text.boot
.global _start
.global m2ld_jump
.global m2ld_clean
.extern m2ld_main
.extern m2_fault_log

_start:
    msr     daifset, #0xf                 /* no interrupts, ever */
    mov     x19, x0                       /* ABL x0 (maybe DTB)  */
    mov     x20, x1                       /* ABL x1              */
    mrs     x21, CurrentEL
    lsr     x21, x21, #2                  /* x21 = EL (1 or 2)   */
    adr     x22, _start                   /* x22 = our VA (== PA under identity) */
    isb

    /* install our vectors at the EL we run at (and the other if reachable) */
    adr     x2, m2_vectors
    cmp     x21, #2
    b.eq    1f
    msr     vbar_el1, x2
    b       2f
1:  msr     vbar_el2, x2
    msr     vbar_el1, x2                  /* for after the eret into EL1 */
2:  isb
    msr     spsel, #1                     /* run on SP_ELx, not SP_EL0 */

    mrs     x23, mpidr_el1
    mrs     x24, midr_el1

    /* stack: image offset STACK_TOP_OFF (256 KiB down), inside the mapped
       decompressed-image window by construction */
    movz    x25, #0x0000
    movk    x25, #0x1c4, lsl #16          /* 0x01c40000 */
    add     sp, x22, x25

    /* m2ld_main(abl_x0, abl_x1, self, mpidr, el, midr) */
    mov     x0, x19
    mov     x1, x20
    mov     x2, x22
    mov     x3, x23
    mov     x4, x21
    mov     x5, x24
    bl      m2ld_main
3:  wfe
    b       3b

/*
 * m2ld_jump(entry_pa, boot_args_pa) — enter XNU at EL1h, MMU stays ON.
 * D-cache for everything we copied is cleaned by the caller; the ic iallu here
 * makes the freshly-memcpy'd instructions visible to fetch.
 */
m2ld_jump:
    msr     daifset, #0xf
    isb
    ic      iallu
    dsb     sy
    isb
    mov     x16, x0                       /* entry PA */
    mov     x0, x1                        /* boot_args PA in x0 */
    mrs     x2, CurrentEL
    lsr     x2, x2, #2
    cmp     x2, #2
    b.ne    1f
    mrs     x2, hcr_el2
    orr     x2, x2, #(1 << 31)            /* RW: EL1 is AArch64 */
    bic     x2, x2, #(1 << 27)            /* TGE off */
    msr     hcr_el2, x2
    mov     w2, #0x3c5                    /* EL1h, DAIF masked */
    msr     spsr_el2, x2
    msr     elr_el2, x16
    eret
1:  br      x16

/*
 * m2ld_return_stub — XNU comes back here through its XNULDRST slot (this
 * kernel's start.s turns SCTLR_EL1.M off before the br). Whatever the MMU
 * state, this must be self-contained: register stores only, no C, no loads,
 * so it also runs with the MMU off. x0=log PA, x1=log len, x2=reason
 * (1 early exception, 2 checkpoint), x3=ESR, x4=ELR, x5=FAR, x6=LR, x7=SP.
 * Raw record at plog+0x800, then an instant watchdog reset.
 */
.global m2ld_return_stub
m2ld_return_stub:
    msr     daifset, #0xf
    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16         /* 0xfd3ff000 */
    movz    w11, #0x5255
    movk    w11, #0x5455, lsl #16         /* "URET" */
    str     w11, [x10, #0x800]
    str     x0, [x10, #0x808]
    str     x1, [x10, #0x810]
    str     x2, [x10, #0x818]
    str     x3, [x10, #0x820]
    str     x4, [x10, #0x828]
    str     x5, [x10, #0x830]
    str     x6, [x10, #0x838]
    str     x7, [x10, #0x840]
    dsb     sy
    /* clean the record + plog head so they survive the reset */
    add     x12, x10, #0x7c0
    add     x15, x10, #0x900
1:  dc      cvac, x12
    add     x12, x12, #64
    cmp     x12, x15
    b.lo    1b
    add     x12, x10, #0x20
    add     x15, x10, #0x1000
2:  dc      cvac, x12
    add     x12, x12, #64
    cmp     x12, x15
    b.lo    2b
    dsb     sy
    /* instant reset on both cluster watchdogs: direct MMIO, no calls */
    movz    x13, #0x4000
    movk    x13, #0x200c, lsl #16
    movz    w14, #0xffee
    movk    w14, #0xc0, lsl #16           /* 0xc0ffee */
    str     w14, [x13, #4]
    str     wzr, [x13]
    mov     w14, #0x100
    str     w14, [x13, #16]
    mov     w14, #0x80
    str     w14, [x13, #8]
    movz    w14, #0x2021
    movk    w14, #0x10, lsl #16
    str     w14, [x13]
    movz    x13, #0x5000
    movk    x13, #0x200c, lsl #16
    movz    w14, #0xffee
    movk    w14, #0xc0, lsl #16
    str     w14, [x13, #4]
    str     wzr, [x13]
    mov     w14, #0x100
    str     w14, [x13, #16]
    mov     w14, #0x80
    str     w14, [x13, #8]
    movz    w14, #0x2021
    movk    w14, #0x10, lsl #16
    str     w14, [x13]
3:  wfe
    b       3b

/* m2ld_clean(va, len) — clean D-cache to PoC for a range (must cover every
   region the loader wrote that XNU will read before its own cache setup). */
m2ld_clean:
    add     x1, x0, x1
    bic     x0, x0, #63
1:  dc      cvac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    1b
    dsb     sy
    ret

/* ---- exception vectors: record + skip ----
 * Sync/SError from the loader's own EL advance ELR by 4 (aborting ldr/str/msr
 * is skipped: the destination register keeps its pre-load sentinel). IRQ/FIQ
 * slots should never fire (DAIF masked); they just eret without advancing. */
.macro VEC off
    mov     x0, #\off
    b       m2_fault_common
    .space  0x78                          /* fixed 0x80 stride per slot */
.endm

m2_fault_common:
    /* save the caller's registers on the current stack (x0 = vector offset) */
    stp     x0, x1, [sp, #-0x30]!
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    mrs     x6, CurrentEL
    lsr     x6, x6, #2
    cmp     x6, #2
    b.eq    1f
    mrs     x2, esr_el1
    mrs     x3, elr_el1
    mrs     x4, far_el1
    b       2f
1:  mrs     x2, esr_el2
    mrs     x3, elr_el2
    mrs     x4, far_el2
2:
    /* append {esr, elr, far, slot} to m2_fault_log (16 slots max) */
    adrp    x7, m2_fault_log
    add     x7, x7, :lo12:m2_fault_log
    ldar    x8, [x7]
    cmp     x8, #16
    b.hs    3f
    add     x9, x7, x8, lsl #5            /* slot = base + 8 + count*32 */
    add     x9, x9, #8
    stlr    x2, [x9]
    str     x3, [x9, #8]
    str     x4, [x9, #16]
    str     x0, [x9, #24]
    add     x8, x8, #1
    stlr    x8, [x7]
3:
    /* advance ELR by 4 for sync-abort slots (offset%0x200 == 0) only */
    tst     x0, #0x1ff
    b.ne    4f
    add     x3, x3, #4
    cmp     x6, #2
    b.eq    31f
    msr     elr_el1, x3
    b       4f
31: msr     elr_el2, x3
4:
    ldp     x4, x5, [sp, #0x20]
    ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp], #0x30
    eret

    /* VBAR needs a 0x80-aligned RUNTIME address. The blob is spliced at
       image+0x1d2a458 (which is 0x58 mod 0x80), so the table's blob offset
       must be 0x28 mod 0x80: align to 0x80, then pad 0x28. */
    .balign 0x80
    .space 0x28
m2_vectors:
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
.global m2_fault_log
m2_fault_log:
    .quad 0                                /* count */
    .space 32 * 16                         /* 16 x {esr, elr, far, slot} */
