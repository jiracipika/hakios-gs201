/*
 * m2blink — make the frozen logo BREATHE: DCS brightness over DSIM.
 *
 * DECON fetch stays unsolved on panther (m2bars/m2bars2: frozen logo; omarchy
 * hasn't cracked panther's flip either — their D3 is pending). But their D2
 * is PROVEN on panther: DCS packets through DSIM0 (base 0x1c2c0000) drive
 * panel brightness — and that works with the panel in self-refresh, no DECON
 * involvement. If the logo dims and brightens on this run, we have a VISIBLE
 * status channel from bare metal (brightness = our progress light), plus the
 * DSIM TX path proven for the future panel driver.
 *
 * Recipe from omarchy gs-dsim-cmd.c (curated/3-display):
 *   PAYLOAD (0x5c) first, payload bytes packed LE per 32-bit word;
 *   then PKTHDR (0x58) = header[0] | header[1]<<8 | header[2]<<16.
 *   DCS long write: DT=0x39, WC=3, payload = [0x51, val_hi, val_lo].
 *   PKT_GO_EN (0x80 bit16) must be off (bootloader leaves it off).
 * Brightness (S6E3FC3, 11-bit MSB first): dim=100 (0x00,0x64),
 * full=2047 (0x07,0xFF), default 1023.
 * Sequence: dim 1s -> full 1s, x2 cycles -> wdt reset.
 */
.section .text
.global _start
_start:
    /* v2 preamble: MMU OFF at entry. m2blink v1 hit the 104s floor — the
       DSIM block (0x1c2c0000) is NOT in ABL's page tables (the blocks ABL
       itself uses — fb/DECON/DPP/wdt/DRAM — all mapped fine). Turning the
       MMU off makes every physical address reachable. Safe under the
       identity-mapping assumption (all prior executing-band stores hit
       their real hardware addresses under the ON mapping, so VA==PA).
       A non-identity map would fault on the next fetch -> 104s floor ->
       self-recovers; that outcome is itself the disproof. */
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

    /* plog marker "m2d" + x0/x1 (x0/x1 saved across the MMU dance in callee
       regs — CurrentEL path clobbers x1; keep the ABL values in x25/x26) */
    mov     x25, x0
    mov     x26, x1
    movz    x10, #0xf000
    movk    x10, #0xfd3f, lsl #16
    movz    w11, #0x4244
    movk    w11, #0x4347, lsl #16          /* DBGC */
    str     w11, [x10]
    str     wzr, [x10, #4]
    movz    w11, #32
    str     w11, [x10, #8]
    movz    w11, #0x326d                   /* 'm','2' */
    movk    w11, #0x0a64, lsl #16          /* 'd','\n' */
    str     w11, [x10, #12]
    str     x25, [x10, #16]
    str     x26, [x10, #24]
    dsb     sy

    movz    x28, #0x0000
    movk    x28, #0x1c2c, lsl #16          /* x28 = DSIM0 base */

    /* 3 loud cycles: near-black (4) 2s <-> full (2047) 2s */
    bl      dark
    bl      wait2s
    bl      full
    bl      wait2s
    bl      dark
    bl      wait2s
    bl      full
    bl      wait2s
    bl      dark
    bl      wait2s
    bl      full
    bl      wait2s

    /* key-wdt reset */
    movz    x20, #0x4000
    movk    x20, #0x200c, lsl #16
    bl      arm
    movz    x20, #0x5000
    movk    x20, #0x200c, lsl #16
    bl      arm
    dsb     sy
1:  wfe
    b       1b

/* send DCS 0x51 with value hi=x30 lo=x31 */
send_bright:
    str     wzr, [x28, #0x68]              /* (defensive) nothing — real poll below */
    /* payload word = 0x51 | hi<<8 | lo<<16 */
    movz    w9, #0x0051
    bfi     w9, w30, #8, #8
    bfi     w9, w31, #16, #8
    str     w9, [x28, #0x5c]               /* PAYLOAD */
    movz    w9, #0x0339                    /* PKTHDR = 0x39 (DCS long) | 3<<8 (WC=3) */
    str     w9, [x28, #0x58]               /* PKTHDR — fires the packet */
    /* spin until PH+PL FIFOs empty (bits 10/8 set) or 16M tries */
    movz    x27, #0x0000
    movk    x27, #0x100, lsl #16           /* 16,777,216 */
20: ldr     w9, [x28, #0x68]               /* FIFOCTRL */
    tst     w9, #0x400                     /* EMPTY_PH_SFR */
    b.eq    21f
    tst     w9, #0x100                     /* EMPTY_PL_SFR */
    b.ne    22f
21: subs    x27, x27, #1
    b.ne    20b
22: dsb     sy
    ret

dark:
    movz    w30, #0x00
    movz    w31, #0x04                     /* 4 — nearly black */
    b       send_bright
full:
    movz    w30, #0x07
    movz    w31, #0xff                     /* 2047 */
    b       send_bright

wait2s:
    mov     x22, #2
23: movz    x21, #0xe100
    movk    x21, #0x5f5, lsl #16           /* 100M iterations ~ 1s */
24: subs    x21, x21, #1
    b.ne    24b
    subs    x22, x22, #1
    b.ne    23b
    ret

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
