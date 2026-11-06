/*
 * gsloader entry (Pixel 7 / gs201).
 * ABL (fastboot boot) decompresses the boot image's kernel and enters it as a Linux
 * arm64 Image: MMU and caches off, x0 = ABL's device tree, at an ABL-chosen physical
 * base. All memory is device memory until XNU turns its MMU on, so the C is built
 * without SIMD and with strict alignment (build.sh).
 * The arm64 Image header carries, like mtkloader: res3 (0x28) = length of a following
 * arm64 Image (unused here), res4 (0x30) = offset of the "XNUP" payload from _start —
 * loader.c reads self+0x30, matching upstream's tools/chainboot.py (0x28 len, 0x30
 * payload offset). 0 means "no payload in the image" (QEMU -device loader test mode).
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
    .quad   0x0a                /* flags 0x0a: LE (bit0=0), 4K pages (bits1-2=01), anywhere (bit3) */
    .quad   0                   /* res2 (0x20) */
    .quad   0                   /* res3 (0x28): following arm64 Image length — unused here */
    .quad   0                   /* res4 (0x30): XNUP payload offset from _start (loader.c reads this) */
    .ascii  "ARM\x64"
    .word   0

primary_entry:
    msr     daifset, #0xf
    /* v4 EXECUTION PROBE (2026-11-06): three payload versions produced byte-
       identical outcomes (104s wdt comeback) — nothing our code did ever
       changed the timeline, so "ABL enters our code" is unproven. This probe
       feeds BOTH cluster watchdogs (WTCNT := WTDAT, config-agnostic canonical
       feed) ~400 rounds (~3-5 min), then parks. If ABL's armed watchdog is
       one of these blocks, the comeback moves from ~104s to ~5-8 min = our
       instructions execute and MMIO writes land. 104s again = code never
       runs (or dies on the first MMIO access). No VBAR, no stack, no C. */
    movz    x22, #0x4000
    movk    x22, #0x200c, lsl #16       /* cl0 */
    movz    x23, #0x5000
    movk    x23, #0x200c, lsl #16       /* cl1 */
    mov     w20, #400
9:  ldr     w1, [x22, #4]               /* WTDAT */
    str     w1, [x22, #8]               /* WTCNT := WTDAT (feed) */
    ldr     w1, [x23, #4]
    str     w1, [x23, #8]
    movz    x21, #0xe100
    movk    x21, #0x5f5, lsl #16
8:  subs    x21, x21, #1
    b.ne    8b
    subs    w20, w20, #1
    b.ne    9b
    wfe
10: b       10b                          /* park: fed wdt fires within one period */

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
    str     wzr, [x0], #4     /* word stride: never writes past __bss_end (an appended
                                  payload starts right after the image; an 8-byte stride
                                  zeroed its first 4 bytes — the XNUP magic) */
    b       1b
2:
    mov     x0, x19
    bl      gsloader_main
3:  wfe
    b       3b

/* PSCI system reset. ABI: x0 = conduit (0 = SMC, 1 = HVC, from the DTB's /psci
   method), w1 = progress code. progress_word bit31 = reset attempt in progress:
   a second trap parks instead of looping (an undefined conduit would otherwise
   re-trap forever — qemu proved that with 822k exceptions). EL1 assumed: SMC/HVC
   are undefined at EL2 (Pixel ABL enters the kernel at EL1; if that ever proves
   wrong, an EL2->EL1 drop is needed before the call). Function ID 0x84000009 =
   SYSTEM_RESET (0x...08 is SYSTEM_OFF — it powers the phone down, no reboot). */
.global gsloader_reset
gsloader_reset:
    adrp    x2, progress_word
    add     x2, x2, :lo12:progress_word
    orr     w1, w1, #0x80000000
    str     w1, [x2]
    cmp     x0, #0
    b.ne    10f
    movz    w0, #0x0009                 /* PSCI SYSTEM_RESET, 32-bit call = 0x84000009 */
    movk    w0, #0x8400, lsl #16
    smc     #0
    b       20f
10: movz    w0, #0x0009
    movk    w0, #0x8400, lsl #16
    hvc     #0
20: wfe
    b       20b

/* Jump to the payload kernel: x0 = entry address, x1 = device tree. ABL entered us
   with MMU/caches off and we never enabled them, so there is nothing to tear down;
   the payload inherits exactly the state ABL gave us (+ a saved copy of nothing). */
.global gsloader_jump
gsloader_jump:
    br      x0

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
