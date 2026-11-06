/*
 * probe12 — entry patch for the STOCK kernel image (v12 experiment).
 * The stock Pixel 7 kernel is an EFI-bootable PE32+ Image (MZ code0, PE header
 * at 0x40, AddressOfEntryPoint RVA 0x1d2a458 -> 'msr daifset,#0xf' = stext).
 * The pristine-stock control run via `fastboot boot` executes (28s watchdog
 * round trip), while every image of ours (plain-Image headers AND MZ clones
 * without a valid PE) never executes a single instruction (104s). Hypothesis:
 * ABL enters the kernel through the PE entry point; our blobs were never
 * PE-valid. This probe is patched INTO the stock kernel at its PE entry,
 * replacing stext's first bytes — everything else byte-stock.
 *
 * EFI-context-safe: no SCTLR/VBAR/exception-state changes (ABL jumps here
 * under its own MMU mappings); only marker stores to the ramoops console zone
 * (DRAM, identity-mapped under UEFI-style page tables) and the key-locked
 * cluster-watchdog arm (MMIO, also identity-mapped under EFI), then park.
 *
 * Marker at 0xfd3ff000: DBGC {sig=0x43474244, start=0, size=32}, data =
 * "V12\n" + raw x0 + raw x1 (the ABL handoff registers — under an EFI-style
 * StartImage these are image-handle / system-table; under a Linux-style entry
 * x0 = DTB — the value tells us which ABI ABL actually used).
 */
.section .text
.global _start
_start:
    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16      /* x10 = 0xfd3ff000 ramoops console */
    movz    w11, #0x4244
    movk    w11, #0x4347, lsl #16      /* w11 = 0x43474244 "DBGC" */
    str     w11, [x10]
    str     wzr, [x10, #4]
    movz    w11, #32
    str     w11, [x10, #8]             /* size = 32 */
    movz    w11, #0x3156
    movk    w11, #0x0a32, lsl #16      /* "V12\n" LE */
    str     w11, [x10, #12]
    str     x0, [x10, #16]             /* ABL x0 (image handle? DTB?) */
    str     x1, [x10, #24]             /* ABL x1 (system table?) */
    dsb     sy

    /* arm cl0 @0x200c4000 then cl1 @0x200c5000: KEY unlock, instant violation */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      arm
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      arm
    dsb     sy
1:  wfe
    b       1b

arm:
    movz    w21, #0xffee
    movk    w21, #0xc0, lsl #16        /* 0xc0ffee */
    str     w21, [x20, #4]             /* KEY unlock */
    str     wzr, [x20]
    mov     w21, #0x100
    str     w21, [x20, #16]            /* WTMINCNT > WTCNT = violation */
    mov     w21, #0x80
    str     w21, [x20, #8]
    movz    w21, #0x2021
    movk    w21, #0x10, lsl #16        /* WTCON = 0x102021 */
    str     w21, [x20]
    ret
