/*
 * m2ld.c — M2 XNU loader for the PE vehicle (Pixel 7 / gs201).
 *
 * Runs where ABL left us: at the stock kernel image's PE entry point, under
 * ABL's MMU (identity — silicon-proven for every block we've touched), with
 * ABL's x0/x1 in hand. Loads the real XNU kernel (Mach-O) from a GSPE blob
 * spliced into the same image, builds the Apple device tree and boot_args the
 * way mtkloader silicon-proved them on this kernel family (text 48 MiB above
 * boot_args.virtBase), arms a calibrated ~45 s watchdog window, and jumps.
 *
 * Observability contract (eyes-free): every step lands in the ramoops console
 * zone at 0xfd3ff000 (cleaned to DRAM so it survives the reset) plus a distinct
 * post-jump timing band. Fault vectors (m2ld.S) skip+log aborts, so probes of
 * unmapped space are recoverable and visible.
 *
 * Port sources: mtkloader.c run_xnu()/build_device_tree() (OSEXGANG
 * hakios-mt6768) — same kernel family as our DEVELOPMENT_ARM64_BCM2837 build
 * (first __TEXT at 0xfffffff007004000, KERNEL_VIRT_BASE 0xfffffff004000000).
 */
#include <stdint.h>
#include <stddef.h>

/* freestanding libc + strlen, defined at the bottom (declared for early use) */
void *memset(void *dst, int c, size_t n);
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
int memcmp(const void *a, const void *b, size_t n);
static size_t strlen(const char *s);

/* ---- vehicle layout (offsets from image base; code itself at AEP) ---- */
#define AEP_OFF        0x1d2a458u   /* stock PE entry RVA == our blob */
#define GSPE_OFF       0x0200000u   /* GSPE manifest + raw Mach-O (~16.0 MiB) */
#define PRAM_OFF       0x1180000u   /* XNU panic-log target, 512 KiB */
#define STACK_TOP_OFF  0x1c40000u
#define IMG_SIZE       0x22e7a00u   /* stock PE SizeOfImage — vehicle length */

/* ---- gs201 MMIO (identity under ABL's map) ---- */
#define PLOG_BASE      0xfd3ff000ull
#define PLOG_SIG       0x43474244u   /* "DBGC" */
#define PLOG_CAP       (256u * 1024u)
#define FB_BASE        0xfac00000ull
#define FB_W           1080u
#define FB_H           2400u
#define FB_PITCH       4320u
#define WDT_CL0        0x200c4000ull
#define WDT_CL1        0x200c5000ull
#define WDT_KEY        0xc0ffeeu

/* WTCON bits (Linux s3c2410_wdt.c + the gs DBGACK quirk at bit 20) */
#define WTCON_RSTEN       (1u << 0)
#define WTCON_ENABLE      (1u << 5)
#define WTCON_DBGACK      (1u << 20)
#define WTCON_PRE(x)      ((uint32_t)(x) << 8)
#define WTCON_ARMED       (WTCON_DBGACK | WTCON_PRE(0x20) | WTCON_ENABLE | WTCON_RSTEN)
#define WTCON_COUNT_ONLY  (WTCON_DBGACK | WTCON_PRE(0x20) | WTCON_ENABLE)

/* ---- XNU placement ---- */
#define KVB            0xfffffff004000000ull  /* boot_args.virtBase */
#define KTEXT_DELTA    0x3000000ull           /* __TEXT sits 48 MiB above it  */
#define PAGE16K        0x4000ull
#define XNU_MEM_TOP    0xf0000000ull          /* keep fb/ramoops out of XNU RAM */
#define XNU_WINDOW_TAIL 0x4400000ull          /* span + DT + boot_args + slack */

/* =====================================================================
 * plog — ramoops console writer (survives the reset once cleaned)
 * ===================================================================== */
static volatile uint32_t *const pl_sig   = (volatile uint32_t *)(uintptr_t)PLOG_BASE;
static volatile uint32_t *const pl_start = (volatile uint32_t *)(uintptr_t)(PLOG_BASE + 4);
static volatile uint32_t *const pl_size  = (volatile uint32_t *)(uintptr_t)(PLOG_BASE + 8);
static volatile uint8_t  *const pl_data  = (volatile uint8_t  *)(uintptr_t)(PLOG_BASE + 12);

void m2ld_clean(uint64_t va, uint64_t len);

static void plog_reset(void)
{
    *pl_sig = PLOG_SIG;
    *pl_start = 0;
    *pl_size = 0;
    m2ld_clean(PLOG_BASE, 0x1000);
}

static void plog_sync(void)
{
    __asm__ volatile("dsb sy" ::: "memory");
    m2ld_clean(PLOG_BASE, 0x40000);
}

static void plog_add(const char *s, uint32_t n)
{
    uint32_t sz = *pl_size;
    if (sz + n > PLOG_CAP) return;
    for (uint32_t i = 0; i < n; i++) pl_data[sz + i] = (uint8_t)s[i];
    *pl_size = sz + n;
}

static void plog_str(const char *s)
{
    uint32_t n = 0;
    while (s[n]) n++;
    plog_add(s, n);
}

static void plog_hex(uint64_t v)
{
    char t[19] = "0x";
    for (int i = 0; i < 16; i++) {
        int d = (int)((v >> ((15 - i) * 4)) & 0xf);
        t[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    }
    t[18] = '\n';
    plog_add(t, 19);
}

static void plog_dec(uint64_t v)
{
    char t[21];
    int i = 20;
    t[i] = 0;
    do { t[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    plog_add(&t[i], (uint32_t)(20 - i));
    plog_add("\n", 1);
}

/* =====================================================================
 * register helpers + watchdog
 * ===================================================================== */
static inline uint32_t rd32(uint64_t a) { return *(volatile uint32_t *)(uintptr_t)a; }
static inline void wr32(uint64_t a, uint32_t v) { *(volatile uint32_t *)(uintptr_t)a = v; }
static inline uint64_t rd_cntfrq(void) { uint64_t v; __asm__ volatile("mrs %0, cntfrq_el0":"=r"(v)); return v; }
static inline uint64_t rd_cntpct(void) { uint64_t v; __asm__ volatile("isb; mrs %0, cntpct_el0":"=r"(v)); return v; }
static inline uint64_t rd_sctlr1(void) { uint64_t v; __asm__ volatile("mrs %0, sctlr_el1":"=r"(v)); return v; }
static inline uint64_t rd_ttbr0_1(void) { uint64_t v; __asm__ volatile("mrs %0, ttbr0_el1":"=r"(v)); return v; }
static inline uint64_t rd_tcr1(void) { uint64_t v; __asm__ volatile("mrs %0, tcr_el1":"=r"(v)); return v; }

static void delay_ms(uint64_t ms, uint64_t frq)
{
    if (!frq) frq = 24576000ull;
    uint64_t until = rd_cntpct() + ms * frq / 1000ull;
    while ((int64_t)(until - rd_cntpct()) > 0) { }
}

/* fault log written by the vectors in m2ld.S: [count][16 x {esr,elr,far,slot}] */
extern uint64_t m2_fault_log[];
static uint64_t fault_count(void)
{
    __asm__ volatile("dmb ish" ::: "memory");
    return *(volatile uint64_t *)(uintptr_t)m2_fault_log;
}

static void plog_faults(const char *tag)
{
    uint64_t n = fault_count();
    plog_str(tag); plog_str(" faults="); plog_dec(n);
    if (n > 16) n = 16;
    volatile uint64_t *fl = (volatile uint64_t *)(uintptr_t)m2_fault_log;
    for (uint64_t i = 0; i < n; i++) {
        plog_str(" esr=");  plog_hex(fl[1 + i * 4 + 0]);
        plog_str(" elr=");  plog_hex(fl[1 + i * 4 + 1]);
        plog_str(" far=");  plog_hex(fl[1 + i * 4 + 2]);
        plog_str(" slot="); plog_hex(fl[1 + i * 4 + 3]);
    }
    plog_sync();
}

static void wdt_stop(uint64_t base)
{
    wr32(base + 0x04, WDT_KEY);
    wr32(base + 0x00, 0);
}

/* the silicon-proven instant window violation (fallback / error path) */
static void wdt_arm_instant(uint64_t base)
{
    wr32(base + 0x04, WDT_KEY);
    wr32(base + 0x00, 0);
    wr32(base + 0x10, 0x100);
    wr32(base + 0x08, 0x80);
    wr32(base + 0x00, WTCON_ARMED);
    __asm__ volatile("dsb sy" ::: "memory");
}

/* Count-only for 1 s on CL0's counter, derive the tick rate, then arm both
 * clusters for ~seconds. Returns the measured ticks/s (0 if unusable). */
static uint64_t wdt_calibrate(void)
{
    uint64_t frq = rd_cntfrq();
    wdt_stop(WDT_CL0);
    wr32(WDT_CL0 + 0x10, 0x100);
    wr32(WDT_CL0 + 0x08, 0x400000);
    uint32_t back = rd32(WDT_CL0 + 0x08);
    wr32(WDT_CL0 + 0x00, WTCON_COUNT_ONLY);
    __asm__ volatile("dsb sy" ::: "memory");
    delay_ms(1000, frq);
    uint32_t now = rd32(WDT_CL0 + 0x08);
    wdt_stop(WDT_CL0);
    uint64_t delta = (uint64_t)0x400000 - (uint64_t)now;
    if (back != 0x400000) delta = 0;              /* WTCNT not 32-bit-writable */
    if (delta < 1000 || delta > 50000000) delta = 0;
    return delta;
}

static void wdt_arm_windowed(uint64_t base, uint64_t rate, uint64_t seconds)
{
    uint64_t cnt = rate * seconds;
    if (cnt > 0xffffff00ull) cnt = 0xffffff00ull;
    cnt += 0x1000;                                 /* window floor margin */
    wr32(base + 0x04, WDT_KEY);
    wr32(base + 0x00, 0);
    wr32(base + 0x10, 0x100);
    wr32(base + 0x08, (uint32_t)cnt);
    wr32(base + 0x00, WTCON_ARMED);
    __asm__ volatile("dsb sy" ::: "memory");
}

/* =====================================================================
 * probes (survive aborts via the skip-vectors)
 * ===================================================================== */
#define PROBE_SENT 0xa5a5deadbeef5a5aULL

static int try_map(uint64_t a)
{
    uint64_t c0 = fault_count();
    uint64_t v = PROBE_SENT;
    __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(a));
    __asm__ volatile("" ::: "memory");
    return v != PROBE_SENT && fault_count() == c0;
}

static int try_rw(uint64_t a)
{
    uint64_t c0 = fault_count();
    uint64_t v = PROBE_SENT;
    uint64_t w = 0x5aa51155aa551155ULL;
    __asm__ volatile("str %0, [%1]" :: "r"(w), "r"(a));
    __asm__ volatile("dsb sy" ::: "memory");
    __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(a));
    __asm__ volatile("" ::: "memory");
    return v == w && fault_count() == c0;
}

/* =====================================================================
 * GSPE payload: manifest + raw kernel Mach-O, built by mkpe-image.py
 * ===================================================================== */
struct gspe_seg { uint64_t vmaddr, vmsize, fileoff, filesize; };
struct gspe_hdr {
    char     magic[8];        /* "GSPE01\0\0" */
    uint32_t hdr_size;        /* offsetof(segs) */
    uint32_t nsegs;
    uint64_t kvb;             /* must equal KVB */
    uint64_t entry_va;        /* LC_UNIXTHREAD pc */
    uint32_t kernel_size;
    uint32_t reserved;
    uint64_t stub_slot_va;    /* XNULDRST slot ("XNULDRST" magic quad), 0 = none */
    /* struct gspe_seg segs[nsegs]; */
    /* uint8_t kernel[kernel_size]; */
};

/* =====================================================================
 * ABL FDT (informational: x0 may be a DTB — log banks if so)
 * ===================================================================== */
#define FDT_MAGIC 0xd00dfeed
#define FDT_BEGIN_NODE 1
#define FDT_END_NODE 2
#define FDT_PROP 3
#define FDT_NOP 4
#define FDT_END 9

static uint32_t ld32(const void *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return __builtin_bswap32(v); }

#define MAXBANKS 8
struct banks { uint64_t base[MAXBANKS], size[MAXBANKS]; int n; };

static void walk_fdt(uint64_t dtb, struct banks *bk)
{
    const uint8_t *b = (const uint8_t *)(uintptr_t)dtb;
    const uint8_t *st = b + ld32(b + 8), *strs = b + ld32(b + 20);
    int ac = 2, sc = 2, depth = 0, in_mem = 0;
    const uint8_t *p = st;
    for (;;) {
        uint32_t tok = ld32(p); p += 4;
        if (tok == FDT_NOP) continue;
        if (tok == FDT_END) return;
        if (tok == FDT_BEGIN_NODE) {
            const char *nm = (const char *)p;
            int len = 0; while (nm[len]) len++;
            p += len + 1; p = (const uint8_t *)((uintptr_t)(p + 3) & ~3ull);
            depth++;
            in_mem = (depth == 2 && len > 7 && __builtin_memcmp(nm, "memory@", 7) == 0);
        } else if (tok == FDT_END_NODE) {
            if (depth == 2) in_mem = 0;
            if (--depth <= 0) return;
        } else if (tok == FDT_PROP) {
            uint32_t len = ld32(p), no = ld32(p + 4);
            const uint8_t *val = p + 8;
            p = (const uint8_t *)((uintptr_t)(p + 8 + len + 3) & ~3ull);
            const char *nm = (const char *)(strs + no);
            if (depth == 1 && len == 4) {
                if (!__builtin_memcmp(nm, "#address-cells", 15)) ac = (int)ld32(val);
                else if (!__builtin_memcmp(nm, "#size-cells", 12)) sc = (int)ld32(val);
            }
            if (in_mem && !__builtin_memcmp(nm, "reg", 4) && len >= (uint32_t)(ac + sc) * 4) {
                uint32_t step = (uint32_t)(ac + sc) * 4;
                for (uint32_t o = 0; o + step <= len && bk->n < MAXBANKS; o += step) {
                    uint64_t ba = 0, sz = 0;
                    for (int i = 0; i < ac; i++) ba = (ba << 32) | ld32(val + o + 4 * i);
                    for (int i = 0; i < sc; i++) sz = (sz << 32) | ld32(val + o + 4 * ac + 4 * i);
                    bk->base[bk->n] = ba; bk->size[bk->n] = sz; bk->n++;
                }
            }
        }
    }
}

static void log_abl_regs(uint64_t ax0, uint64_t ax1)
{
    struct banks bk = { .n = 0 };
    plog_str("ax0="); plog_hex(ax0);
    plog_str("ax1="); plog_hex(ax1);
    for (int which = 0; which < 2; which++) {
        uint64_t a = which ? ax1 : ax0;
        uint64_t c0 = fault_count();
        uint32_t m = 0;
        __asm__ volatile("ldr %w0, [%1]" : "=r"(m) : "r"(a));
        __asm__ volatile("" ::: "memory");
        if (fault_count() != c0) { plog_str(which ? "x1-unmapped\n" : "x0-unmapped\n"); continue; }
        if (m == FDT_MAGIC) {
            plog_str(which ? "x1=FDT\n" : "x0=FDT\n");
            walk_fdt(a, &bk);
        } else {
            plog_str(which ? "x1=" : "x0="); plog_hex(m); plog_str("\n");
        }
    }
    plog_str("fdt-banks="); plog_dec((uint64_t)bk.n);
    for (int i = 0; i < bk.n && i < 4; i++) {
        plog_str(" b"); plog_dec((uint64_t)i);
        plog_hex(bk.base[i]); plog_hex(bk.size[i]);
    }
    plog_sync();
}

/* =====================================================================
 * Apple device tree (mtkloader's writer; identity-free placeholder values)
 * ===================================================================== */
struct dt_writer { uint8_t *base, *cur; uint32_t *counts[16]; int depth; };

static void dt_prop(struct dt_writer *w, const char *name, const void *data, uint32_t len)
{
    memset(w->cur, 0, 32);
    memcpy(w->cur, name, strlen(name));
    *(volatile uint32_t *)(w->cur + 32) = len;
    memset(w->cur + 36, 0, (len + 3) & ~3u);
    memcpy(w->cur + 36, data, len);
    w->cur += 36 + ((len + 3) & ~3u);
    w->counts[w->depth - 1][0]++;
}
static void dt_prop_str(struct dt_writer *w, const char *name, const char *v)
{ dt_prop(w, name, v, (uint32_t)strlen(v) + 1); }
static void dt_prop_u32(struct dt_writer *w, const char *name, uint32_t v)
{ dt_prop(w, name, &v, sizeof(v)); }
static void dt_prop_u64(struct dt_writer *w, const char *name, uint64_t v)
{ dt_prop(w, name, &v, sizeof(v)); }
static void dt_prop_pad(struct dt_writer *w, const char *name, const char *v, uint32_t size)
{
    uint8_t f[64];
    memset(f, 0, sizeof(f));
    memcpy(f, v, strlen(v));
    dt_prop(w, name, f, size);
}
static void dt_begin(struct dt_writer *w, const char *name)
{
    if (w->depth > 0) w->counts[w->depth - 1][1]++;
    w->counts[w->depth++] = (uint32_t *)w->cur;
    memset(w->cur, 0, 8);
    w->cur += 8;
    dt_prop_str(w, "name", name);
}
static void dt_end(struct dt_writer *w) { w->depth--; }

/* empty CHRP NVRAM image (IOKit wants one) */
#define NVRAM_BANK_SIZE 0x2000u
static uint8_t nvram_image[NVRAM_BANK_SIZE];

static void nvram_chrp_header(uint8_t *h, uint8_t sig, uint32_t bytes, const char *name)
{
    uint16_t blocks = (uint16_t)(bytes / 16), sum;
    memset(h, 0, 16);
    h[0] = sig;
    h[2] = (uint8_t)blocks;
    h[3] = (uint8_t)(blocks >> 8);
    memcpy(h + 4, name, strlen(name));
    sum = h[0];
    for (int i = 2; i < 16; i++) sum += h[i];
    while (sum > 0xff) sum = (uint16_t)((sum & 0xff) + (sum >> 8));
    h[1] = (uint8_t)sum;
}

static void build_nvram_image(uint8_t *image)
{
    uint32_t lo = 1, hi = 0, generation = 1;
    memset(image, 0, NVRAM_BANK_SIZE);
    nvram_chrp_header(image, 0x5a, 0x20, "nvram");
    nvram_chrp_header(image + 0x20, 0x70, NVRAM_BANK_SIZE - 0x20, "common");
    memcpy(image + 20, &generation, 4);
    for (uint32_t i = 20; i < NVRAM_BANK_SIZE; i++) {
        lo = (lo + image[i]) % 65521;
        hi = (hi + lo) % 65521;
    }
    uint32_t adler = (hi << 16) | lo;
    memcpy(image + 16, &adler, 4);
}

static uint32_t build_apple_dt(uint64_t dt_pa, uint64_t pb, uint64_t memsize,
                               uint64_t mpidr, uint64_t cntfrq, uint64_t pram_pa)
{
    struct dt_writer w = { .base = (uint8_t *)(uintptr_t)dt_pa,
                           .cur = (uint8_t *)(uintptr_t)dt_pa, .depth = 0 };
    uint8_t seed[64];
    for (unsigned i = 0; i < sizeof(seed); i++)
        seed[i] = (uint8_t)(rd_cntpct() >> (i & 7)) ^ (uint8_t)(i * 37);

    dt_begin(&w, "device-tree");
    dt_prop_str(&w, "platform-name", "t8015");
    dt_prop_pad(&w, "serial-number", "HAKIOS0000000000", 32);
    dt_prop_u32(&w, "#address-cells", 2);
    dt_prop_u32(&w, "#size-cells", 2);

    dt_begin(&w, "chosen");
    dt_prop_str(&w, "darwin-board", "panther");
    dt_prop(&w, "random-seed", seed, sizeof(seed));
    dt_prop_u64(&w, "dram-base", pb);
    dt_prop_u64(&w, "dram-size", memsize);
    dt_prop_u32(&w, "debug-enabled", 1);
    dt_prop_u32(&w, "display-scale", 2);
    dt_prop_u32(&w, "display-rotation", 0);
    dt_prop_str(&w, "psci-method", "smc");
    dt_prop_u64(&w, "unique-chip-id", 0x000052445730001ULL);
    dt_prop_u32(&w, "chip-id", 0x8015);
    dt_prop_u32(&w, "board-id", 0x06);
    static const uint8_t mac_wifi[6] = { 0x02, 0x48, 0x41, 0x4b, 0x00, 0x01 };
    static const uint8_t mac_bt[6]   = { 0x02, 0x48, 0x41, 0x4b, 0x00, 0x02 };
    static const uint8_t manifest_hash[48] = { 'h', 'a', 'k', 'i', 'o', 's' };
    static const uint8_t no_behavior[16];
    dt_prop(&w, "mac-address-wifi0", mac_wifi, sizeof(mac_wifi));
    dt_prop(&w, "mac-address-bluetooth0", mac_bt, sizeof(mac_bt));
    dt_prop(&w, "boot-manifest-hash", manifest_hash, sizeof(manifest_hash));
    dt_prop(&w, "software-behavior", no_behavior, sizeof(no_behavior));
    dt_prop_str(&w, "firmware-version", "iBoot-8796.121.2");
    dt_prop_u32(&w, "certificate-production-status", 1);
    dt_prop_u32(&w, "certificate-security-mode", 1);
    dt_prop_u32(&w, "effective-production-status-ap", 1);
    dt_prop_u32(&w, "effective-security-mode-ap", 1);
    dt_prop_u32(&w, "secure-boot", 1);
    dt_prop_u32(&w, "production-cert", 1);
    dt_prop_u32(&w, "development-cert", 0);
    dt_prop_u32(&w, "embedded-panic-log-size", 0x80000);
    build_nvram_image(nvram_image);
    dt_prop_u32(&w, "nvram-bank-size", NVRAM_BANK_SIZE);
    dt_prop_u32(&w, "nvram-bank-count", 1);
    dt_prop_u32(&w, "nvram-current-bank", 0);
    dt_prop(&w, "nvram-proxy-data", nvram_image, sizeof(nvram_image));
    dt_end(&w);

    dt_begin(&w, "defaults");
    dt_prop_u32(&w, "kern.vm_compressor", 2);
    dt_end(&w);

    dt_begin(&w, "product");
    dt_end(&w);

    dt_begin(&w, "options");
    dt_end(&w);

    uint64_t pram_reg[2] = { pram_pa, 0x80000 };
    dt_begin(&w, "pram");
    dt_prop(&w, "reg", pram_reg, sizeof(pram_reg));
    dt_end(&w);

    dt_begin(&w, "cpus");
    dt_begin(&w, "cpu0");
    dt_prop_str(&w, "device_type", "cpu");
    dt_prop_str(&w, "state", "running");
    dt_prop_u32(&w, "reg", (uint32_t)(mpidr & 0xffffffu));
    dt_prop_u32(&w, "cpu-id", 0);
    dt_prop_u64(&w, "timebase-frequency", cntfrq);
    dt_prop_u64(&w, "fixed-frequency", cntfrq);
    dt_prop_u64(&w, "clock-frequency", 2304000000ull);
    dt_prop_u64(&w, "bus-frequency", 100000000ull);
    dt_prop_u64(&w, "memory-frequency", 100000000ull);
    dt_prop_u64(&w, "peripheral-frequency", 24000000ull);
    dt_end(&w);
    dt_end(&w);

    dt_begin(&w, "arm-io");
    dt_prop_str(&w, "device_type", "panther");
    uint64_t ranges[3] = { 0, 0x10000000, 0x10000000 };
    dt_prop(&w, "ranges", ranges, sizeof(ranges));
    dt_prop_u32(&w, "#address-cells", 2);
    dt_prop_u32(&w, "#size-cells", 2);

    dt_begin(&w, "gic");
    dt_prop_str(&w, "device_type", "interrupt-controller");
    dt_prop_str(&w, "compatible", "arm,gic-v3");
    uint64_t gic_reg[4] = { 0x400000, 0x10000, 0x440000, 0x400000 };
    dt_prop(&w, "reg", gic_reg, sizeof(gic_reg));
    dt_end(&w);

    dt_end(&w);
    dt_end(&w);
    return (uint32_t)(w.cur - w.base);
}

/* =====================================================================
 * boot_args (pexpert/arm64/boot.h shape; mtkloader-asserted offsets)
 * ===================================================================== */
struct boot_video {
    uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};
#define BOOT_LINE_LENGTH 608
struct boot_args {
    uint16_t revision;
    uint16_t version;
    uint64_t virtBase;
    uint64_t physBase;
    uint64_t memSize;
    uint64_t topOfKernelData;
    struct boot_video video;
    uint32_t machineType;
    uint64_t deviceTreeP;
    uint32_t deviceTreeLength;
    char commandLine[BOOT_LINE_LENGTH];
    uint64_t bootFlags;
    uint64_t memSizeActual;
};
_Static_assert(__builtin_offsetof(struct boot_args, virtBase) == 8, "ba");
_Static_assert(__builtin_offsetof(struct boot_args, physBase) == 16, "ba");
_Static_assert(__builtin_offsetof(struct boot_args, video) == 40, "ba");
_Static_assert(__builtin_offsetof(struct boot_args, deviceTreeP) == 96, "ba");
_Static_assert(__builtin_offsetof(struct boot_args, commandLine) == 108, "ba");
_Static_assert(__builtin_offsetof(struct boot_args, bootFlags) == 720, "ba");

/* =====================================================================
 * main
 * ===================================================================== */
void m2ld_jump(uint64_t entry_pa, uint64_t args_pa);
extern char m2ld_return_stub[];   /* asm; XNU's XNULDRST slot br's here */

static uint64_t g_img_base, g_self, g_pb;

/* memory ceiling for an XNU window: keep fb/ramoops out of low-bank windows */
static uint64_t mem_top_for(uint64_t pb)
{
    return pb >= 0x800000000ull ? pb + 0x40000000ull : XNU_MEM_TOP;
}

/* pick a phys window: probe 2 MiB steps over [pb, pb+span); rw-check the ends */
static int window_ok(uint64_t pb, uint64_t span)
{
    if (pb & 0x1fffff) return 0;
    if (pb + span >= mem_top_for(pb)) return 0;
    for (uint64_t a = pb; a < pb + span; a += 0x200000) {
        if (!try_map(a)) {
            plog_str("unmapped @"); plog_hex(a);
            return 0;
        }
    }
    if (!try_rw(pb + 0x1000)) { plog_str("rw-fail @pb\n"); return 0; }
    if (!try_rw(pb + span - 0x200000 + 0x1000)) { plog_str("rw-fail @end\n"); return 0; }
    return 1;
}

void m2ld_main(uint64_t ax0, uint64_t ax1, uint64_t self, uint64_t mpidr,
               uint64_t el, uint64_t midr)
{
    uint64_t frq = rd_cntfrq();
    g_self = self;
    g_img_base = self - AEP_OFF;

    plog_reset();
    plog_str("M2LD v1\n");
    plog_str("self=");      plog_hex(self);
    plog_str("imgbase=");   plog_hex(g_img_base);
    plog_str("el=");        plog_dec(el);
    plog_str("mpidr=");     plog_hex(mpidr);
    plog_str("midr=");      plog_hex(midr);
    plog_str("cntfrq=");    plog_dec(frq);
    plog_str("sctlr_el1="); plog_hex(rd_sctlr1());
    plog_str("tcr_el1=");   plog_hex(rd_tcr1());
    plog_str("ttbr0_el1="); plog_hex(rd_ttbr0_1());
    plog_sync();
    log_abl_regs(ax0, ax1);
    plog_faults("post-regs");

    /* ---- GSPE manifest ---- */
    const struct gspe_hdr *h = (const struct gspe_hdr *)(uintptr_t)(g_img_base + GSPE_OFF);
    if (__builtin_memcmp(h->magic, "GSPE01", 6) != 0) {
        plog_str("err B1 no-gspe\n"); plog_sync();
        wdt_arm_instant(WDT_CL0); wdt_arm_instant(WDT_CL1);
        for (;;) __asm__ volatile("wfe");
    }
    if (h->kvb != KVB || h->nsegs == 0 || h->nsegs > 32 ||
        h->kernel_size == 0 || h->kernel_size > 0x1200000u) {
        plog_str("err B2 bad-manifest\n"); plog_sync();
        wdt_arm_instant(WDT_CL0); wdt_arm_instant(WDT_CL1);
        for (;;) __asm__ volatile("wfe");
    }
    const struct gspe_seg *segs = (const struct gspe_seg *)(uintptr_t)((uint64_t)h + h->hdr_size);
    const uint8_t *kfile = (const uint8_t *)(uintptr_t)((uint64_t)segs + h->nsegs * sizeof(*segs));

    uint64_t vm_lo = ~0ull, vm_hi = 0;
    for (uint32_t i = 0; i < h->nsegs; i++) {
        if (!segs[i].vmsize) continue;
        if (segs[i].vmaddr < vm_lo) vm_lo = segs[i].vmaddr;
        if (segs[i].vmaddr + segs[i].vmsize > vm_hi) vm_hi = segs[i].vmaddr + segs[i].vmsize;
    }
    plog_str("gspe nsegs="); plog_dec(h->nsegs);
    plog_str(" ksize=");     plog_dec(h->kernel_size);
    plog_str(" entry_va=");  plog_hex(h->entry_va);
    plog_str(" vmlo=");      plog_hex(vm_lo);
    plog_str(" vmhi=");      plog_hex(vm_hi);
    plog_sync();
    if (h->entry_va < vm_lo || h->entry_va >= vm_hi) {
        plog_str("err B4 entry-outside\n"); plog_sync();
        wdt_arm_instant(WDT_CL0); wdt_arm_instant(WDT_CL1);
        for (;;) __asm__ volatile("wfe");
    }

    /* ---- XNU phys window (ladder; everything is probed, nothing assumed) ---- */
    uint64_t span = (vm_hi - KVB) + 0x200000;   /* kernel + DT + args + slack */
    uint64_t pb0 = (g_img_base + IMG_SIZE + 0x1fffffull) & ~0x1fffffull;
    uint64_t cands[4] = { pb0, pb0 + 0x4000000ull, pb0 + 0x10000000ull, 0x880000000ull };
    uint64_t pb = 0;
    for (int i = 0; i < 4; i++) {
        plog_str("try pb="); plog_hex(cands[i]); plog_sync();
        if (window_ok(cands[i], span)) { pb = cands[i]; break; }
    }
    if (!pb) {
        plog_str("err F3 no-window\n"); plog_sync();
        wdt_arm_instant(WDT_CL0); wdt_arm_instant(WDT_CL1);
        for (;;) __asm__ volatile("wfe");
    }
    g_pb = pb;
    uint64_t slide = pb - KVB;
    uint64_t memsize = mem_top_for(pb) - pb;
    plog_str("pb="); plog_hex(pb);
    plog_str("span="); plog_hex(span);
    plog_str("memsize="); plog_hex(memsize);
    plog_sync();

    /* ---- copy segments (memset vmsize, memcpy filesize) ---- */
    for (uint32_t i = 0; i < h->nsegs; i++) {
        if (!segs[i].vmsize) continue;
        uint64_t fc0 = fault_count();
        uint64_t dst = segs[i].vmaddr + slide;
        memset((void *)(uintptr_t)dst, 0, segs[i].vmsize);
        memcpy((void *)(uintptr_t)dst, kfile + segs[i].fileoff, segs[i].filesize);
        if (fault_count() != fc0) { plog_str("fault-in-copy seg="); plog_dec(i); plog_sync(); }
        plog_str("seg ");  plog_dec(i);
        plog_str(" -> ");  plog_hex(dst);
        plog_str(" +");    plog_dec(segs[i].vmsize);
        plog_str(" f=");   plog_dec(segs[i].filesize);
        plog_str("\n");
    }
    plog_faults("post-copy");
    plog_sync();

    /* verify the first 8 bytes of __TEXT actually landed (MH magic there) */
    {
        uint64_t t = segs[0].vmaddr + slide;   /* first seg = __TEXT at fileoff 0 */
        uint32_t m0 = rd32(t), m1 = rd32(t + 4);
        plog_str("text@"); plog_hex(t);
        plog_str(" =");    plog_hex(((uint64_t)m1 << 32) | m0);
        plog_sync();
    }

    /* ---- Apple DT + boot_args after the kernel ---- */
    uint64_t kern_hi = (vm_hi + slide + PAGE16K - 1) & ~(PAGE16K - 1);
    uint64_t pram_pa = g_img_base + PRAM_OFF;
    memset((void *)(uintptr_t)pram_pa, 0, 0x80000);
    uint64_t dt_pa = kern_hi;
    uint32_t dt_len = build_apple_dt(dt_pa, pb, memsize, mpidr, frq, pram_pa);
    uint64_t ba_pa = (dt_pa + dt_len + PAGE16K - 1) & ~(PAGE16K - 1);
    uint64_t top = ba_pa + PAGE16K;

    struct boot_args *ba = (struct boot_args *)(uintptr_t)ba_pa;
    memset(ba, 0, sizeof(*ba));
    ba->revision = 2;
    ba->version = 2;
    ba->virtBase = KVB;
    ba->physBase = pb;
    ba->memSize = memsize;
    ba->memSizeActual = memsize;
    ba->topOfKernelData = top;
    ba->deviceTreeP = dt_pa - slide;          /* kernel-virtual address */
    ba->deviceTreeLength = dt_len;
    ba->video.v_baseAddr = FB_BASE;
    ba->video.v_display = 1;
    ba->video.v_rowBytes = FB_PITCH;
    ba->video.v_width = FB_W;
    ba->video.v_height = FB_H;
    ba->video.v_depth = 32;
    static const char cmdline[] = "debug=0x8 cpus=1 ";
    memcpy(ba->commandLine, cmdline, sizeof(cmdline));

    plog_str("dt@");    plog_hex(dt_pa);
    plog_str(" len=");  plog_dec(dt_len);
    plog_str(" ba@");   plog_hex(ba_pa);
    plog_str(" top=");  plog_hex(top);
    plog_str(" entry=");plog_hex(h->entry_va + slide);
    plog_sync();

    /* ---- clean everything we wrote that XNU will read ---- */
    m2ld_clean(pb, top - pb);                 /* kernel + DT + boot_args */
    m2ld_clean(g_img_base + GSPE_OFF, 0x1000);
    m2ld_clean(pram_pa, 0x80000);
    m2ld_clean(g_img_base + PRAM_OFF - 0x80000, STACK_TOP_OFF - PRAM_OFF + 0x80000);
    m2ld_clean(PLOG_BASE, 0x40000);
    plog_faults("post-clean");

    /* ---- XNULDRST: register our return stub so an early exception or a
     * checkpoint in the kernel jumps back to m2ld_return_stub (with the MMU
     * off) instead of dying in place — the report lands at plog+0x800 ---- */
    if (h->stub_slot_va) {
        volatile uint64_t *slot = (volatile uint64_t *)(uintptr_t)(h->stub_slot_va + slide);
        if (slot[0] == 0x545352444c554e58ULL) {     /* "XNULDRST" */
            slot[1] = (uint64_t)(uintptr_t)m2ld_return_stub;
            slot[2] = 0;                            /* checkpoint: disabled */
            slot[3] = slide;
            __asm__ volatile("dsb sy" ::: "memory");
            m2ld_clean((uint64_t)slot, 64);
            plog_str("stub reg @"); plog_hex((uint64_t)slot);
            plog_str(" -> ");        plog_hex(slot[1]);
            plog_sync();
        } else {
            plog_str("stub magic mismatch @"); plog_hex((uint64_t)slot);
            plog_str(" ="); plog_hex(slot[0]);
            plog_sync();
        }
    }

    /* ---- watchdog: calibrated ~45 s window, fallback instant ---- */
    {
        uint64_t rate = wdt_calibrate();
        plog_str("wdt-rate="); plog_dec(rate); plog_sync();
        if (rate >= 1000) {
            wdt_arm_windowed(WDT_CL0, rate, 45);
            wdt_arm_windowed(WDT_CL1, rate, 45);
            plog_str("wdt armed 45s\n");
        } else {
            plog_str("wdt cal failed -> instant\n");
            wdt_arm_instant(WDT_CL0); wdt_arm_instant(WDT_CL1);
        }
        plog_sync();
    }

    plog_str("JUMP\n"); plog_sync();
    m2ld_jump(h->entry_va + slide, ba_pa);

    /* never reached; belt and braces */
    plog_str("err B5 jump-returned\n"); plog_sync();
    wdt_arm_instant(WDT_CL0); wdt_arm_instant(WDT_CL1);
    for (;;) __asm__ volatile("wfe");
}

/* =====================================================================
 * freestanding libc (clang lowers builtins to these)
 * ===================================================================== */
static size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
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
