# Pixel 7 (panther)

A HakiOS device repository: what is true of this device and of no other. The kernel, the loader, the drivers and the tools are
the common repository's; the gs201 family's facts are in `soc/`, carried with the device. How the three are put together:
[docs/porting/repositories.md](https://github.com/oosexgang/hakios-xnu-kernel/blob/main/docs/porting/repositories.md).

| File | What |
|---|---|
| `device.conf` | what the device is, and how far each part of it works: its page in the documentation is made from it |
| `configs/panther_defconfig` | the common kernel, the SoC's fragment, this device's: `make panther_defconfig` |
| `configs/panther.config` | what is this device's own: the drivers built in, the arguments it needs |
| `soc/` | its SoC family's layer (gs201): `soc.conf`, `configs/gs201.config`, the SoC's drivers; carried here so that this one repository is all the device needs |
| `drivers/` | drivers of its own, if it needs any (`drivers/<subsystem>/conf`, as in the common repository) |

Every phone driver of the common repository is left out to begin with: their addresses and pins are the phone they were written
for. Put one back in `configs/panther.config` when it has been made to work here, and say so in `device.conf`.

Check with `tools/hakios-device.py check panther`.
