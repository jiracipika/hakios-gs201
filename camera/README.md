# panther camera workstream (features branch)

Front + rear camera bring-up for the Pixel 7, milestone CM0–CM5
(see parent repo `docs/FEATURES.md` §1 for the full evidence chain).

## Verdict (decided 2026-11-04)

**Rewrite.** No upstream repo has any camera code — Google's Lyric HAL + LWIS +
Exynos ISP stack is closed-source in the vendor image. We take Google's *shape*
(DT-described devices + power sequences, which the stock dtbo hands us verbatim)
and write the gs201 side ourselves. No vendor code is copied; DTBO facts
(addresses, rails, sequences) are data, not code.

## What exists here now

- `panther_camera.h` — module descriptors: sensor codenames (svarog front,
  barghest rear-main, imentet rear-uw), i2c addresses/buses, and the board-ops
  interface the sequencer needs.
- `panther_camera.c` — the power sequences transcribed from the stock overlay
  (`module_power_seq@1/@2/@3`) with their exact delays, and the sequencer.
- Milestones below.

## Milestones

| step | what | status |
|---|---|---|
| CM0 | pin the active overlay variant on the phone (`adb shell getprop ro.boot.dtbo_idx`) — confirms panther's sensor set | needs phone |
| CM1 | gs201 I2C controller (LSIOE/LSIOS cli*) + rail control (PP1050_CAM GPIO regulator, SLG51002 PMIC) feeding `pc_board_ops` | blocked by M0/M1 (XNU on hardware) |
| CM2 | run front module power seq (`pc_module_power_up(PC_MODULES[0])`), verify rails/MCLK/reset with the sequencing above; reconcile the down-seq normalization comment in panther_camera.c against the raw overlay | CM1 |
| CM3 | front sensor i2c probe: 3J1 ID registers read (0x10 @ lsioe_cli8) — first "camera alive" signal | CM2 |
| CM4 | CD-PHY + CSIS raw frame dump (front first: no AF/OIS) | CM3 + GIC/SMMU |
| CM5 | rear main frame (barghest; needs nessie AF/OIS reset dance), then ISP minimal path | CM4 |

## Sensor identity (vendor HAL proof)

| codename | panther role | vendor config evidence |
|---|---|---|
| svarog | front (3J1 10.8MP) | `rango_frontinner_svarog_normal.binarypb` |
| barghest | rear main (GN1-class 50MP, OIS) | `rango_rear_barghest_normal.binarypb` (240fps modes) |
| imentet | rear UW (12MP) | `rango_rear_imentet_wide.binarypb` + `eeprom-smaug-imentet-uw` |
| dokkaebi-tele | (7 Pro only) | `rango_rear_dokkaebi_tele.binarypb` |
| tarasque | ToF (7 Pro only) | Lyric ToF driver strings |

The dtbo.img carries 11 overlay variants — board-rev selection for the rango
family (panther + cheetah share the silicon); tele/ToF nodes exist in all
variants but only instantiate on modules that ship. CM0 pins ours.
