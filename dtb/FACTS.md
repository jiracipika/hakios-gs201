# Pixel 7 (panther / gs201 / "lga") device-tree facts

Extracted 2026-11-04 from the stock factory image `rango-bp4a.251205.006`
(SHA-256 e042c4f062fadaae585a862e2b61405df45130e57f4a44e153059d173b0d8a95).

## Where the kernel DTB actually lives

- `boot.img` kernel blob: pure lz4-legacy stream, **no DTB inside**.
- `vendor_boot.img`: dtb_size=0 (dtb_loadaddr=0x11f00000 is where ABL stages what it
  hands the kernel).
- `vendor_kernel_boot.img`: **dtb_size=1443893 at dtb_loadaddr=0x11f00000** — two
  concatenated DTBs (this directory):
  - `panther-lga-base.dtb`  (720286 bytes, fdt 17)
  - `panther-lga-base-2.dtb` (723607 bytes — second variant, near-identical)
- The ABL image (`bootloader-rango-deepspace-16.4-14378951.img`, "FBPK" container)
  holds its own firmware tree (`google,acfw`, 135501 bytes at 0x18de10) — firewall
  (`sswrp`) config, NOT the kernel DTB.
- Nodes seen on the live system (`mali@28000000`, `memory@880000000`, clusters) come
  from the dtbo partition overlays + ABL runtime fixups (memory/`chosen`), not the
  base tree. `dtbo.img` holds ~11 overlay blobs of ~270KB each at 2048-stride.

## Load-relevant facts from the base tree

| Item | Value |
|---|---|
| root compatible | `google,lga` |
| `/psci` method | **`smc`** (compatible `arm,psci-1.0`) |
| GIC | `arm,gic-v3` at `interrupt-controller@5880000` |
| kernel_loadaddr (vendor_boot hdr) | `0x10008000` |
| ramdisk_loadaddr (vendor_boot hdr) | `0x11000000` |
| dtb_loadaddr | `0x11f00000` |
| tags_addr | `0x10000100` |
| UART0 | `0x10A00000` (`earlycon=exynos4210` from the ROM cmdline; console=ttySAC0) |
| RAM base (from live tree) | `0x880000000` (banks filled by ABL at boot) |
| vendor_boot page size | 2048 (boot.img page size is 4096) |
| cpus | placeholder `gem5,armv8` nodes in base tree (cpu@0/100/200/...); ABL/kernel fixes up 2×X1 + 2×A78 + 4×A55 |
| vendor cmdline (vendor_boot) | cgroup/rcu/swiotlb tuning + `bootconfig`; no console= (ABL adds) |

## Stock boot.img decode (rango BP4A.251205.006)

- Android boot image **v4**: `header_size=1584` (v3's 1580 + trailing
  `recovery_ds_size=0`), `kernel_size=17195325`, `ramdisk_size=0`, `os_version=0`,
  `header_version=4`, cmdline zero-filled (1536), page 4096.
- Kernel blob = **lz4 LEGACY stream** (magic `0x184c2102`, 5 blocks of the 8MB-block
  default), no gzip, no appended DTB, blob accounts to kernel_size exactly.
- Container = full 64MB partition image: `AVB0` vbmeta immediately after the
  page-aligned kernel blob (0x1068000 for stock), `AVBf` footer in the last 64 bytes.
- `fastboot boot` implication: ABL gets a file shaped like the partition image; the
  `panther-boot-avb.img` variant patches a copy of the real stock image in place
  (header + kernel region), keeping stock vbmeta/footer offsets — the Magisk-patch
  shape that is known to ramboot on Pixels.
