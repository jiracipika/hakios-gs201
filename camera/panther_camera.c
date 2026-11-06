/* panther_camera.c — module power sequencing per the stock dtbo lwiscamera
 * fragment. The data below is transcribed from overlay 00 of the factory
 * rango-bp4a.251205.006 dtbo.img (see panther_camera.h for addresses/buses).
 * The sequencer itself is ours: regulator/GPIO/pinctrl calls arrive through
 * pc_board_ops, which the gs201 SoC layer (CM1) implements on top of ACPM/PMIC.
 * Until then pc_board_ops is the only unknown — no other hidden state exists. */
#include "panther_camera.h"

#include <stddef.h>

/* ---- front: module_power_seq@1 (inner_front) ---- */
const struct pc_seq_step PC_SEQ_FRONT_UP[] = {
    { "pp3200_bb", PC_REGULATOR, 1000 },
    { "vio",       PC_REGULATOR, 0 },
    { "gpio3",     PC_REGULATOR, 2000 },
    { "ldo12s",    PC_REGULATOR, 0 },
    { "reset",     PC_GPIO,      1000 },
    { "mclk_on",   PC_PINCTRL,   1000 },
    { "resume",    PC_CONTROLLER, 0 },
};
const struct pc_seq_step PC_SEQ_FRONT_DOWN[] = {
    { "suspend",   PC_CONTROLLER, 0 },
    { "mclk_off",  PC_PINCTRL,   1000 },
    { "reset",     PC_GPIO,      1000 },
    { "ldo12s",    PC_REGULATOR, 1000 },
    { "gpio3",     PC_REGULATOR, 1000 },
    { "vio",       PC_REGULATOR, 1000 },
    { "pp3200_bb", PC_REGULATOR, 2000 },
};

/* ---- rear main: module_power_seq@2 (barghest + nessie AF/OIS/EEPROM) ---- */
const struct pc_seq_step PC_SEQ_MAIN_UP[] = {
    { "pp3200_bb",          PC_REGULATOR, 0 },
    { "pp1050",             PC_REGULATOR, 0 },
    { "shared-vana_enable", PC_GPIO,      0 },
    { "vio",                PC_REGULATOR, 1000 },
    { "ldo1",               PC_REGULATOR, 1000 },
    { "ldo2",               PC_REGULATOR, 1000 },
    { "gpio1",              PC_REGULATOR, 1000 },
    { "ldo8",               PC_REGULATOR, 1000 },
    { "mclk_on",            PC_PINCTRL,   1000 },
    { "resume",             PC_CONTROLLER, 0 },
};
const struct pc_seq_step PC_SEQ_MAIN_DOWN[] = {
    { "suspend",            PC_CONTROLLER, 0 },
    { "mclk_off",           PC_PINCTRL,   1000 },
    { "resume_hold",        PC_GPIO,      1000 },   /* mirror of the up-side gpio1 step; DT spells
                                                         the down list "suspend mclk_off reset ldo*..."
                                                         — normalized here, see README step CM2 */
    { "ldo8",               PC_REGULATOR, 1000 },
    { "gpio1",              PC_REGULATOR, 1000 },
    { "ldo2",               PC_REGULATOR, 1000 },
    { "ldo1",               PC_REGULATOR, 1000 },
    { "vio",                PC_REGULATOR, 1000 },
    { "shared-vana_enable", PC_GPIO,      1000 },
    { "pp1050",             PC_REGULATOR, 0 },
    { "pp3200_bb",          PC_REGULATOR, 2000 },
};

/* ---- rear uw: module_power_seq@3 (imentet) ---- */
const struct pc_seq_step PC_SEQ_UW_UP[] = {
    { "pp3200_bb",          PC_REGULATOR, 0 },
    { "pp1050",             PC_REGULATOR, 0 },
    { "shared-vana_enable", PC_GPIO,      0 },
    { "vio",                PC_REGULATOR, 0 },
    { "ldo5",               PC_REGULATOR, 1000 },
    { "gpio2",              PC_REGULATOR, 1000 },
    { "ldo6",               PC_REGULATOR, 1000 },
    { "mclk_on",            PC_PINCTRL,   10000 },
    { "resume",             PC_CONTROLLER, 0 },
};
const struct pc_seq_step PC_SEQ_UW_DOWN[] = {
    { "suspend",            PC_CONTROLLER, 0 },
    { "mclk_off",           PC_PINCTRL,   1000 },
    { "ldo6",               PC_REGULATOR, 1000 },
    { "gpio2",              PC_REGULATOR, 1000 },
    { "ldo5",               PC_REGULATOR, 1000 },
    { "vio",                PC_REGULATOR, 0 },
    { "shared-vana_enable", PC_GPIO,      0 },
    { "pp1050",             PC_REGULATOR, 0 },
    { "pp3200_bb",          PC_REGULATOR, 0 },
};

/* PC_MODULES defined directly (a second copy initialized from the first is not a
   compile-time constant in C — rejected by clang/gcc alike). */
const struct pc_module PC_MODULES[] = {
    { "svarog",    "front",     PC_BUS_FRONT, PC_I2C_ADDR_FRONT_SVAROG,
      PC_SEQ_FRONT_UP, 7, PC_SEQ_FRONT_DOWN, 7 },
    { "barghest",  "rear-main", PC_BUS_MAIN,  PC_I2C_ADDR_MAIN_BARGHEST,
      PC_SEQ_MAIN_UP, 10, PC_SEQ_MAIN_DOWN, 11 },
    { "imentet",   "rear-uw",   PC_BUS_UW,    PC_I2C_ADDR_UW_IMENTET,
      PC_SEQ_UW_UP, 9, PC_SEQ_UW_DOWN, 9 },
};
const size_t PC_MODULE_COUNT = 3;

static int run_seq(const struct pc_seq_step *s, size_t n, const struct pc_board_ops *ops,
                   int power_on)
{
    for (size_t i = 0; i < n; i++, s++) {
        int rc;
        switch (s->type) {
        case PC_REGULATOR:
            rc = power_on ? ops->regulator_enable(s->name) : ops->regulator_disable(s->name);
            break;
        case PC_GPIO:
            rc = ops->gpio_set(s->name, power_on);
            break;
        case PC_PINCTRL:
            rc = ops->pinctrl_apply(s->name);
            break;
        case PC_CONTROLLER:
            rc = ops->controller_cmd(s->name);
            break;
        default:
            return -1;
        }
        if (rc) return rc;
        if (s->delay_us) ops->delay_us(s->delay_us);
    }
    return 0;
}

int pc_module_power_up(const struct pc_module *m, const struct pc_board_ops *ops)
{
    return run_seq(m->up, m->up_len, ops, 1);
}

int pc_module_power_down(const struct pc_module *m, const struct pc_board_ops *ops)
{
    return run_seq(m->down, m->down_len, ops, 0);
}
