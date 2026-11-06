/* gsloader v0 — heartbeat experiment (Pixel 7 / gs201).
 * Purpose: prove the ABL contract for `fastboot boot` on panther: ABL decompresses the
 * boot image's kernel, enters it as an arm64 Image with x0 = its device tree, at an
 * ABL-chosen physical base. Everything observable today happens through ONE signal:
 * gsloader resets the phone with a code (heartbeat). If the phone reboots itself to
 * Android seconds after `fastboot boot`, ABL ran our loader — and the reset code
 * (shown by fastboot as the reboot reason on some ROMs, and stored in progress_word)
 * says how far it got. This v0 does NOT start XNU: the gs201 SoC layer is still blank.
 */
#include <stdint.h>
#include <stddef.h>

void gsloader_reset(uint64_t conduit, uint32_t code);

extern uint8_t _start[];
volatile uint32_t progress_word;

/* ---- minimal libfdt: header walk, /memory regs, root cells ---- */
#define FDT_MAGIC 0xd00dfeed
struct fdt_header { uint32_t magic, totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap, version, last_comp, boot_cpuid, size_strings; };
#define FDT_BEGIN_NODE 1
#define FDT_END_NODE 2
#define FDT_PROP 3
#define FDT_NOP 4
#define FDT_END 9
#define XNUP_MAGIC 0x584e5550u   /* ASCII "XNUP" bytes as ld32 (big-endian) reads them;
                                     the mtkloader reference native-reads the same bytes */

static uint32_t ld32(const void *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return __builtin_bswap32(v); }

struct walker { const uint8_t *st; const uint8_t *str; };

static uint64_t cells_be(const uint8_t *p, int n)
{
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v = (v << 32) | ld32(p + 4 * i);
    return v;
}

#define MAXBANKS 8
struct banks { uint64_t base[MAXBANKS], size[MAXBANKS]; int n; };

static void walk_tree(const struct walker *w, struct banks *bk, int *addr_cells, int *size_cells,
                      int *psci_hvc)
{
    const uint8_t *p = w->st;
    int depth = 0, in_memory = 0, in_psci = 0;
    for (;;) {
        uint32_t tok = ld32(p); p += 4;
        if (tok == FDT_NOP) continue;
        if (tok == FDT_END) return;
        if (tok == FDT_BEGIN_NODE) {
            const char *nm = (const char *)p;
            int len = 0; while (nm[len]) len++;
            p += len + 1; p = (const uint8_t *)((uintptr_t)(p + 3) & ~3ull);
            depth++;
            in_memory = (depth == 2 && (len == 6 || (len > 7 && __builtin_memcmp(nm, "memory@", 7) == 0)));
            in_psci   = (depth == 2 && __builtin_memcmp(nm, "psci", 4) == 0);
        } else if (tok == FDT_END_NODE) {
            if (depth == 2) { in_memory = 0; in_psci = 0; }
            depth--;
            if (depth <= 0) return;
        } else if (tok == FDT_PROP) {
            uint32_t len = ld32(p), nameoff = ld32(p + 4);
            const uint8_t *val = p + 8;
            p = (const uint8_t *)((uintptr_t)(p + 8 + len + 3) & ~3ull);
            const char *nm = (const char *)(w->str + nameoff);
            if (depth == 1 && len == 4) {
                if (!__builtin_memcmp(nm, "#address-cells", 15)) *addr_cells = (int)ld32(val);
                else if (!__builtin_memcmp(nm, "#size-cells", 12)) *size_cells = (int)ld32(val);
            }
            if (in_psci && !__builtin_memcmp(nm, "method", 7) && len >= 4)
                *psci_hvc = (__builtin_memcmp(val, "hvc", 3) == 0);
            if (in_memory && len >= 16 && !__builtin_memcmp(nm, "reg", 4)) {
                int s_ac = *addr_cells > 0 ? *addr_cells : 2, s_sc = *size_cells > 0 ? *size_cells : 2;
                uint32_t step = (uint32_t)(s_ac + s_sc) * 4;
                for (uint32_t o = 0; o + step <= len && bk->n < MAXBANKS; o += step) {
                    bk->base[bk->n] = cells_be(val + o, s_ac);
                    bk->size[bk->n] = cells_be(val + o + 4 * s_ac, s_sc);
                    bk->n++;
                }
            }
        }
    }
}

/* XNUP discovery: Image-header res4 (file offset 0x30) = payload offset from _start
   (boot image mode — upstream chainboot.py writes it there); fallback: fixed
   0xF0000000 (QEMU -device loader mode, like upstream's BootShim) — but only if a
   parsed memory bank actually covers that address (blind probes fault). */
static const uint8_t *xnup_find(uintptr_t self, const struct banks *bk)
{
    uint64_t off = *(volatile uint64_t *)(self + 0x30);
    if (off && ld32((const void *)(self + off)) == XNUP_MAGIC) return (const uint8_t *)(self + off);
    for (int i = 0; i < bk->n; i++) {
        uint64_t lo = bk->base[i], hi = lo + bk->size[i];
        if (0xF0000000ull >= lo && 0xF0000003ull < hi && ld32((const void *)0xF0000000ull) == XNUP_MAGIC)
            return (const uint8_t *)0xF0000000ull;
    }
    return 0;
}

void gsloader_main(uint64_t dtb)
{
    struct fdt_header h;
    const uint8_t *b = (const uint8_t *)dtb;
    if (ld32(b) != FDT_MAGIC) gsloader_reset(0, 0xF0);            /* no DTB from ABL */
    __builtin_memcpy(&h, b, sizeof h);
    struct walker w = { b + ld32(&h.off_dt_struct), b + ld32(&h.off_dt_strings) };

    struct banks bk = { .n = 0 };
    int ac = 2, sc = 2, psci_hvc = -1;                          /* -1: unknown */
    walk_tree(&w, &bk, &ac, &sc, &psci_hvc);

    if (bk.n == 0) gsloader_reset(0, 0xF1);                       /* no /memory parsed */
    if (bk.size[0] < (64ull << 20)) gsloader_reset(0, 0xF2);      /* bank looks wrong */

    const uint8_t *x = xnup_find((uintptr_t)_start, &bk);
    /* gsloader_reset conduit arg: 0 = SMC, 1 = HVC (from the DTB's /psci method;
       default SMC — qemu virt and Pixel ABL both default to it).
       reset code = what was learned:
         0xB0 memory parsed, XNUP payload found
         0xB1 memory parsed, no payload (the plain heartbeat boot image) */
    gsloader_reset(psci_hvc < 0 ? 0 : (uint64_t)psci_hvc, x ? 0xB0u : 0xB1u);
}

/* ---- freestanding: clang lowers the builtins to these calls (mtkloader does the same) ---- */
void *memset(void *dst, int c, size_t n)
{
    uint8_t *d = dst;
    for (size_t i = 0; i < n; i++) d[i] = (uint8_t)c;
    return dst;
}
void *memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = dst; const uint8_t *s = src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}
void *memmove(void *dst, const void *src, size_t n)
{
    uint8_t *d = dst; const uint8_t *s = src;
    if (d < s) { for (size_t i = 0; i < n; i++) d[i] = s[i]; }
    else { for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1]; }
    return dst;
}
int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
}
