# Upstream research — 2026-11-06

## "They fixed WiFi and SEP" — verified

### WiFi: REAL, but only for other SoCs (nothing for us)
- `OOSEXGANG/hakios-mt6768` — **gen4m driver works on MT6768** (Infinix Hot 20): scan,
  WPA2 join from Settings, the Internet and Safari over the phone's own radio.
  `4f270371` 2026-11-05 "wifi: the gen4m driver"; README updated 2026-11-06.
  Files: `kernel/bsd/dev/redwood_connsys.c`, `redwood_mtkwifi.c`, `redwood_wpa.c`
  (**in-kernel WPA**).
- `OOSEXGANG/hakios-xnu-kernel` — **ath11k works on redwood/SM7325** (POCO X5 Pro):
  `3a57ccb8` 2026-10-13 "Wi-Fi works on the phone" (WPA2 join + page fetch over the
  radio), `4c6b1843` 2026-10-14 (55-70 Mbit/s: block ack, interrupts, wide channel),
  `c8a69069` OpenSSH over own WiFi (10-19), `80f5042c` `hakios.wlan.cpp` WiFi as an
  IONetworkController under the "wlan" node (10-29).
- **Pixel 7's WiFi chip is Broadcom BCM4389** (omarchy gs201 DTS). **Zero Broadcom
  work exists in any XNU project.** Our bring-up will be a brcmfmac/bcmdhd-style
  port; omarchy's BCM4389 brcmfmac series (10-11..13: D3 ACK, msgbuf fixes, PCIe
  ring polling, 6 GHz chanspecs) documents the chip quirks; HakiOS's wlan
  IONetworkController + in-kernel WPA is the kernel-side integration template.

### SEP: NOT fixed — software keychain only
- What actually happened: **UniXNU** (separate org, target Xiaomi Pad 6S Pro/SM8550):
  `AppleKeyStoreState` `54546377` **2026-11-05** "fix(keystore): wrap keys in software"
  — answers AppleKeyStore wrap/unwrap/bag-UUID/generation/cache selectors with a
  device key derived from platform unique identity, so the keychain stores/reads
  items WITHOUT a Secure Enclave. Plus `SoftwareAES`, `QcaBluetooth` (11-05),
  `QcomDwc3` USB (11-06), `Ath12kWifi` (11-03).
- HakiOS itself: software key store since 2026-10-14 ("the key store wraps keys");
  README 2026-10-20 still said Apple-account sign-in "stops at the missing Secure
  Enclave"; the 2026-11-04 README rewrite dropped SEP mention entirely. **No
  sepfw/SEP emulation exists anywhere.**

## Repo restructure (2026-10-30..11-05) — sync targets
- SoC/device layers re-homed into `OOSEXGANG/hakios-xnu-kernel` (`devices/`, `mtk/`,
  `soc/`, `DEVICE=`/`.config` selection via `xl`/`mkxnuimg`); loader is now the
  top-level `xnuloader/` directory (the standalone repos never existed — GitHub
  search 0 hits). MediaTek device lives on the `mtk` branch (head `3f31f342`,
  2026-11-06, "Wi-Fi join from Settings and Safari over it").
- `hakios-mt6768` keeps its own `mtkloader/`; `hakios-metal` merged into the kernel
  repo (2.3.3, 11-05); kernel at 2.3.4 (11-05).
- **Zero gs201/Tensor/Pixel commits or issues anywhere** — jiracipika/hakios-gs201
  is first-of-kind.
- Community ports in flight: SM8450 dipper #52, SM8735 onyx #50, SM8475 mayfly #47,
  MT6833 #46/#48, SM8150 vayu #31, oneplus-6t #37, raphael #26, SM8350 GIC #21.

## omarchy-mobile (Linux, gs201 hardware reference)
- `derekross/linux-omarchy-mobile` (v7.3-rc6+Tensor, pushed 11-05): panther BT
  `0a6f97a2` (11-01), rear flash LED (11-04), **cheetah BCM4389 WiFi enable
  `7b7565d6`** (10-11) + brcmfmac BCM4389 series, GNSS SPI (11-02).
- `derekross/omarchy-mobile`: `omamobile-device-panther` 0.1.6→0.1.9 this week
  (AVB footers, radio partitions/nv-backup, camera + DMA heap rule).
