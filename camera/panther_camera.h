/* panther_camera.h — Pixel 7 camera module descriptors, straight from the stock
 * dtbo overlay's "lwiscamera" fragment (factory rango-bp4a.251205.006, overlay 00)
 * and the vendor Lyric-HAL config names. No guessed values: every entry cites its
 * DTBO source. Evidence file for the CM1–CM5 milestones (docs/FEATURES.md §1).
 *
 * Google's own kernel side is LWIS (lwis.ko): DT-described devices that the HAL
 * sequences. We keep the same shape — plain descriptors + a sequencer — without
 * copying any code. */
#ifndef PANTHER_CAMERA_H
#define PANTHER_CAMERA_H

#include <stdint.h>
#include <stddef.h>   /* size_t in the module descriptors below */

/* ---- i2c addresses / buses (dtbo: sensor@N / actuator@N / ... node facts) ---- */
#define PC_I2C_ADDR_FRONT_SVAROG     0x10   /* sensor@1  node-name sensor-svarog */
#define PC_I2C_ADDR_MAIN_BARGHEST    0x10   /* sensor@0  node-name sensor-barghest */
#define PC_I2C_ADDR_UW_IMENTET       0x2d   /* sensor@3  node-name sensor-imentet */
#define PC_I2C_ADDR_EEP_MAIN         0x24   /* eeprom@0  eeprom-nessie (shared with AF/OIS) */
#define PC_I2C_ADDR_EEP_FRONT        0x50   /* eeprom@1  eeprom-smaug-svarog */
#define PC_I2C_ADDR_EEP_UW           0x50   /* eeprom@3  eeprom-smaug-imentet-uw */
#define PC_I2C_ADDR_ACT_MAIN         0x24   /* actuator@0 act-nessie (rear main AF) */
#define PC_I2C_ADDR_OIS_MAIN         0x24   /* ois@0      ois-nessie (rear main OIS) */
#define PC_I2C_ADDR_FLASH            0x63   /* flash@0    flash-lm3644 */

/* i2c controller instance the overlay assigns each module to (fixup symbols):
 * front svarog   -> LSIOE cli8 (sensor@1, eeprom@1)
 * rear main      -> LSIOS cli1 (sensor@0, act@0, ois@0, eeprom@0, flash via cli7)
 * rear uw        -> LSIOE cli13 (sensor@3, act@1, eeprom@3)
 * The gs201 I2C controller driver (CM1) maps these cli names to register bases. */
#define PC_BUS_FRONT   "lsioe_cli8"
#define PC_BUS_MAIN    "lsios_cli1"
#define PC_BUS_UW      "lsioe_cli13"
#define PC_BUS_FLASH   "lsioe_cli7"

/* ---- power sequence steps (dtbo module_power_seq@N; verbatim names) ---- */
enum pc_seq_type { PC_REGULATOR, PC_GPIO, PC_PINCTRL, PC_CONTROLLER };

struct pc_seq_step {
    const char *name;       /* rail/GPIO/pinctrl name as the overlay spells it */
    enum pc_seq_type type;
    uint32_t delay_us;      /* applied AFTER the step (overlay's delays-us) */
};

/* module_power_seq@1 — inner_front (svarog, the panther front camera).
 * up:   pp3200_bb(1ms) vio(0) gpio3(2ms) ldo12s(0) reset(1ms) mclk_on(1ms) resume(0)
 * down: suspend(0) mclk_off(1ms) reset(1ms) ldo12s(1ms) gpio3(1ms) vio(1ms) pp3200_bb(2ms) */
extern const struct pc_seq_step PC_SEQ_FRONT_UP[];
extern const struct pc_seq_step PC_SEQ_FRONT_DOWN[];

/* module_power_seq@2 — rear_main (barghest + nessie complex).
 * up:   pp3200_bb(0) pp1050(0) shared-vana_enable-as-gpio(0) vio(1ms) ldo1(1ms)
 *       ldo2(1ms) gpio1(1ms) ldo8(1ms) mclk_on(1ms) resume(0) */
extern const struct pc_seq_step PC_SEQ_MAIN_UP[];
extern const struct pc_seq_step PC_SEQ_MAIN_DOWN[];

/* module_power_seq@3 — rear_uw (imentet).
 * up:   pp3200_bb(0) pp1050(0) shared-vana_enable-as-gpio(0) vio(0) ldo5(1ms)
 *       gpio2(1ms) ldo6(1ms) mclk_on(10ms) resume(0)  — note the 10ms before resume */
extern const struct pc_seq_step PC_SEQ_UW_UP[];
extern const struct pc_seq_step PC_SEQ_UW_DOWN[];

struct pc_module {
    const char *codename;   /* vendor HAL codename (Lyric configs use rango_<role>_<codename>) */
    const char *role;       /* front | rear-main | rear-uw on panther */
    const char *sensor_i2c_bus;
    uint8_t sensor_i2c_addr;
    const struct pc_seq_step *up;   const size_t up_len;
    const struct pc_seq_step *down; const size_t down_len;
};

/* panther instantiates three of the five family sensors (no tele, no ToF).
 * Which overlay variant applies is pinned at CM0 (ro.boot.dtbo_idx); the variant
 * may drop the unused front-outer (svarog-outer) instance. */
extern const struct pc_module PC_MODULES[];
extern const size_t PC_MODULE_COUNT;

/* ---- sequencer interface the gs201 SoC layer must provide (CM1) ---- */
struct pc_board_ops {
    int (*regulator_enable)(const char *name);     /* pp3200_bb, vio, ldo12s, pp1050, ... */
    int (*regulator_disable)(const char *name);
    int (*gpio_set)(const char *name, int on);     /* reset lines, shared-vana_enable, gpio1..4 */
    int (*pinctrl_apply)(const char *state);       /* mclk_on / mclk_off */
    int (*controller_cmd)(const char *name);       /* resume / suspend (sensor-level, i2c later) */
    void (*delay_us)(uint32_t us);
};

int pc_module_power_up(const struct pc_module *m, const struct pc_board_ops *ops);
int pc_module_power_down(const struct pc_module *m, const struct pc_board_ops *ops);

#endif /* PANTHER_CAMERA_H */
