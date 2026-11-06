# GPU bring-up research — Mali G710 (Tensor G2 / gs201) — banked 2026-11-06

## Chip facts
- Pixel 7 GPU = Arm Mali-G710 (10-core), **CSF architecture (arch 10.x)** — firmware-driven
  command stream frontend, NOT the older Job Manager (panfrost) interface.
- **Upstream driver: `panthor`** (Linux 6.10+). Panfrost does not drive CSF GPUs at the
  register level. XNU-side: no Mali driver exists; one would be a panthor-style port.
- **Firmware: `mali_csffw`** from linux-firmware `arm/mali/arch10.8/` (Redistributable
  license). The phone's own r54p3 blob is arch-incompatible.

## omarchy-mobile findings (gs201 hardware reference, Linux)
- panthor works on gs201 with: **fixed 151 MHz clock, no regulators** (the counterintuitive
  part — the GPU comes up with the bootloader's clock state; the driver's own power/clock
  paths fight the PMIC setup).
- Patches series around Oct 2025 got panthor+KMS usable on gs101/gs201 devices.
- Display console (independent of GPU): DECON0 TRIG_CON (0x1c240030)=0x3061 + fb writes —
  **proven on cheetah, FAILED on panther** (frozen logo; the DPP SHD_REG_UP_REQ poke also
  didn't help; DECON never refetches on panther). DSIM0 (0x1c2c0000) DCS writes to the
  panel DO work (brightness) — but DSIM is clock-gated in the fastboot environment
  (external abort regardless of MMU state). Panel: S6E3FC3-P10.
- CMU maps: CMU_DISP 0x1c200000, CMU_DPU 0x1c000000 (SFR_BLOCK lists pulled from
  pantah gs201 kernel branch); no DSIM-named gate found in CMU_DISP/DPU gate lists —
  the gate hunt needs CAL vclk tables or dtbo live nodes.

## XNU-side plan (post-M2)
1. M2 first: XNU boots headless (framebuffer passed via boot_args video; invisible until
   DECON is solved — display is decoupled from GPU).
2. Port order: panthor-register-level bring-up with mali_csffw loaded from the loader
   (add a "gpu-fw" GSPE entry), fixed-clock/no-regulator config copying omarchy's
   quirks. IOKit controller analogous to hakios.wlan.cpp's IONetworkController pattern.
3. Userspace: Metal-on-Vulkan path upstream (Turnip/Metal-on-Vulkan merged into the
   hakios kernel tree Nov 5, hakios-metal 2.3.3) is the eventual renderer.
