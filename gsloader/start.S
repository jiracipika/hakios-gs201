/*
 * gsloader entry (Pixel 7 / gs201).
 * ABL (fastboot boot) decompresses the boot image's kernel and enters it as a Linux
 * arm64 Image: MMU and caches off, x0 = ABL's device tree, at an ABL-chosen physical
 * base. All memory is device memory until XNU turns its MMU on, so the C is built
 * without SIMD and with strict alignment (build.sh).
 * The arm64 Image header carries, like mtkloader: res2 = length of a following arm64
 * Image (unused here), res3 = offset of the "XNUP" payload from _start (mkpayload.py
 * container). 0 means "no payload in the image" (QEMU -device loader test mode).
 */
.global _start
.global gsloader_vectors

.section .text.boot
_start:
    /* Linux ARM64 Image header (64 bytes) */
    b       primary_entry       /* code0 */
    .word   0                   /* code1 = exec below if entered as raw */
    .quad   0x80000             /* text_offset */
    .quad   0x02000000          /* image_size (covering; patched by mkboot if needed) */
    .quad   0x0a                /* flags: little-endian, 4K pages, anywhere */
    .quad   0                   /* res2 */
    .quad   0                   /* res3: XNUP offset from _start (patched by mkboot) */
    .quad   0                   /* res4 */
    .ascii  "ARM\x64"
    .word   0

primary_entry:
    msr     daifset, #0xf
    mov     x19, x0                     /* device tree pointer from ABL */

    mrs     x1, CurrentEL
    lsr     x1, x1, #2
    adrp    x2, gsloader_vectors
    add     x2, x2, :lo12:gsloader_vectors
    cmp     x1, #2
    b.ne    10f
    msr     vbar_el2, x2
    b       20f
10: msr     vbar_el1, x2
20:
    /* stack just below the load address, BSS cleared */
    adr     x0, _start
    sub     x0, x0, #0x8000
    mov     sp, x0
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.ge    2f
    str     xzr, [x0], #8
    b       1b
2:
    mov     x0, x19
    bl      gsloader_main
3:  wfe
    b       3b

/* progress codes land here before the reset heartbeat; a host reads them back
   (phone: nothing yet; qemu: exit + log). x20 = code. */
.global gsloader_progress
gsloader_progress:
    adrp    x21, progress_word
    add     x21, x21, :lo12:progress_word
    str     w20, [x21]
    /* also mirror to the first page below _start for a warm-reboot reader */
    ret

/* PSCI system reset. ABI: x0 = conduit (0 = SMC, 1 = HVC, from the DTB's /psci
   method), w1 = progress code. progress_word bit31 = reset attempt in progress:
   a second trap parks instead of looping (an undefined conduit would otherwise
   re-trap forever — qemu proved that with 822k exceptions). */
.global gsloader_reset
gsloader_reset:
    adrp    x2, progress_word
    add     x2, x2, :lo12:progress_word
    orr     w1, w1, #0x80000000
    str     w1, [x2]
    cmp     x0, #0
    b.ne    10f
    movz    w0, #0x0008                 /* PSCI SYSTEM_RESET, 32-bit call = 0x84000008 */
    movk    w0, #0x8400, lsl #16
    smc     #0
    b       20f
10: movz    w0, #0x0008
    movk    w0, #0x8400, lsl #16
    hvc     #0
20: wfe
    b       20b

/* any exception: one HVC-first reset attempt, then park. No recursion. */
.global gsloader_trap
gsloader_trap:
    adrp    x2, progress_word
    add     x2, x2, :lo12:progress_word
    ldr     w3, [x2]
    tbnz    w3, #31, 40f
    mov     x0, #1                      /* HVC first: qemu virt and EL1 PSCI are hvc */
    mov     w1, #0x00ee
    b       gsloader_reset
40: wfe
    b       40b

.balign 2048
gsloader_vectors:
    .rept   16
    b       gsloader_trap
    .space  124
    .endr
