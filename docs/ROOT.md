# ROOT — the root filesystem, and the road to a shell on panther (Pixel 7 / gs201)

Design note for the HakiOS Pixel 7 port. Written 2026-11-06 from the upstream
repositories and our own tree; every claim carries its source. Anything not
confirmed in code is marked **UNVERIFIED**.

Repos/refs used (all verified locally):

- `oosexgang/hakios-xnu-kernel` branch `main` @ `2631f5d` (remote ref `upstream/main`)
- `oosexgang/hakios-xnu-kernel` branch `mtk` @ `db08f63` (remote ref `upstream/mtk`)
- `oosexgang/hakios-mt6768` (device repo, `main`; fetched via `gh api` today)
- our fork, branch `pixel7` @ `4678bee` (kernel tree `xnu-src/xnu-8796.121.2`
  with the current `xnu/hakios.patch` applied), `devices/panther/` work tree

---

## 0. TL;DR

- Upstream has **two root schemes**, both selected purely by boot-args plus a
  DT node:
  1. `rd=md0` — RAM-disk root: the loader declares the image in the Apple
     device tree at `/chosen/memory-map` as property `RAMDisk` = `{pa, size}`;
     the kernel turns it into `/dev/md0` and mounts it (APFS) as `/`.
  2. `rd=md0 emmc_root=1` — flash root (MT6768 only): the kernel reads the
     system image out of the `xnusys` eMMC partition on demand through
     `bsd/dev/redwood_emmc.c`; `rd=md0` stays on the command line for
     user space (libignition), not for mounting.
- The old `packfs` image format is **gone** upstream; every image is now an
  **APFS container** built by `tools/apfs/mkapfs.py`
  (mtk `docs/ru/notes.md` ~l.1273: "packfs нет ни в ядре ... ни в сборке").
- Smallest credible ladder for us, ranked by effort:
  - **(c) first light** — `hello` (16 KB static Mach-O, already builds in our
    tree at `userland/hello`) as the whole ramdisk; XNU's own **mockfs**
    presents it as `/sbin/launchd` = process 1. No APFS, no dyld, no shell —
    proof of userspace in a plog/serial line. Hours of work.
  - **(a) ramdisk root via GSPE** — extend our GSPE container with a
    `ramdisk` record, copy it above the kernel inside the XNU window, declare
    `memory-map`/`RAMDisk` in the Apple DT m2ld already builds, add `rd=md0`.
    First with `root.apfs` (13.4 MB upstream: our init + rc + launchd jobs),
    which fits the boot-image ramdisk channel that `mkpe-bare.sh` proved.
    Days of work. **The full 2.4 GB `system.apfs` does not fit the
    `fastboot boot` channel — full iOS waits for (b).**
  - **(b) UFS root** — gs201's UFS host controller (`ufs@3c400000`,
    `google,ufshc` in the stock DTB). Upstream's kernel UFS code *assumes the
    controller was already brought up by resident UEFI* (redwood/SM7325); on
    panther nothing is resident, so this means writing full UFSHCI bring-up.
    Weeks, and the right long-term answer.

---

## 1. How root works upstream today

### 1.1 The loader's side: `memory-map` / `RAMDisk` / `RAMDisk1`

Both upstream loaders (the UEFI one and mtkloader) build an **Apple-format
device tree** and put the ramdisk(s) in a `memory-map` node under `/chosen`:

- `xnuloader/loader.c` (main) l.3284-3298:
  ```
  dt_begin(&w, "memory-map");
  /* "RAMDisk" becomes /dev/md0, the root (the kernel and launchd treat
     only md0 as a RAM disk boot); "RAMDisk1" becomes /dev/md1. */
  uint64_t first[2] = { rd_pa, rd_size };   dt_prop(&w, "RAMDisk",  first, 16);
  uint64_t second[2] = { rd1_pa, rd1_size }; dt_prop(&w, "RAMDisk1", second, 16);
  ```
  The property payload is a pair of native u64: **physical address, size**.
- `mtk/loader/mtkloader.c` (mtk branch) l.868-886, same shape, plus the rule:
  with the big system image present it is `RAMDisk` (md0) and the payload's
  small one is `RAMDisk1` (md1); with `emmc_root` there is no md0 and the
  payload image is declared as `RAMDisk1` (md1) alone.
- Placement: the payload ramdisk is copied to `rd_pa = kern_hi` — the first
  16K-aligned physical address above the kernel's highest segment, i.e.
  **inside the kernel's static mapping, below `topOfKernelData`**
  (loader.c l.2911: "The ramdisk must sit inside the kernel's static mapping,
  i.e. below topOfKernelData"; l.2912-2913; mtkloader.c l.2274-2280). A root
  image too big for the payload area goes at a fixed offset inside the window,
  `RESIDENT_RD_OFFSET = 0x08000000` above `physBase` (loader.c l.29-34,
  l.2944-2959; mtkloader.c l.34-35 `SYSTEM_PA = XNU_PHYS_BASE + 0x08000000`).
  The DT follows the last image, boot_args follows the DT (mtkloader.c
  l.2286-2289, loader.c l.2962-2965).
- Boot-args: loader.c l.3123-3143 — base `"debug=0x8 serial=3 "` (only with a
  UART), `"cpus=1 "`, and `"rd=md0 "` whenever a ramdisk exists and the
  payload cmdline doesn't carry its own `rd=`. mtkloader.c l.128-137:
  `XNU_ROOT_EMMC=1` (default) → `"rd=md0 emmc_root=1"`, else plain `"rd=md0"`.

### 1.2 The kernel's side: md0, rd=md0, and which filesystem mounts

All of this is in our tree already (`xnu-src/xnu-8796.121.2`, patch applied):

1. `iokit/bsddev/IOKitBSDInit.cpp` `IOFindBSDRoot()`:
   - l.753-770 (stock XNU + comment): reads `/chosen/memory-map` property
     `RAMDisk`, calls `mdevadd(-1, ml_static_ptovirt(pa) >> 12, size >> 12, 0)`
     — the image becomes memory device **md0** (`/dev/md0`).
   - l.776-781 (hakios.patch, main variant): `RAMDisk1` → `mdevadd(-1, ...)` —
     becomes **md1** when md0 already exists. The mtk branch strengthens this
     to `mdevadd(mdevlookup(1) == -1 ? 1 : -1, ...)` so the image is **md1
     even without an md0** (needed for `emmc_root`, where the payload's small
     image rides as md1 while the root is on flash) — mtk `xnu/hakios.patch`,
     IOKitBSDInit hunk, context lines around "md1 even without an md0".
     **Our tree has the main variant; that is fine for option (a), where we
     use `RAMDisk` (md0) directly.**
   - l.689 (patch): a `rd=md*` boot-arg cuts the `waitForMatchingService`
     wait from 30 s to 0.1 s ("A memory-device root needs no filesystem
     kext").
   - l.787-829: `rd=mdN` → `*root = mdevlookup(N)`, rootName `"md0"`,
     `panic("IOFindBSDRoot: specified root memory device, %s, has not been
     configured")` if absent (l.826). So **`rd=md0` is what makes the kernel
     root on the ramdisk without waiting for a block-device kext**.
2. `bsd/vfs/vfs_subr.c` `vfs_mountroot()` l.1210+: walks `vfsconf` trying
   each filesystem's `mountroot` in registration order.
   `bsd/vfs/vfs_conf.c` l.258-261: **APFS is registered before mockfs**;
   "a device that is not APFS comes back EINVAL and vfs_mountroot() goes on
   to the next", and l.287: "mockfs should always be the last standard entry
   (and thus the last FS we attempt mountroot with)" — mockfs "accepts any
   root device".
3. So the ramdisk content decides the filesystem:
   - **APFS container** (starts with `NXSB` at offset 32 of the image) →
     `apfs_mountroot` succeeds → the image is the root volume
     (`bsd/miscfs/apfs/apfs_vfsops.c`, read-only driver; format in
     `bsd/miscfs/apfs/apfs_format.h`).
   - **A bare static Mach-O** (no NXSB) → APFS says EINVAL → **mockfs**
     (`bsd/miscfs/mockfs/mockfs_vfsops.c` l.55+) builds a three-node
     filesystem in which the ramdisk *itself* is presented as
     `/sbin/launchd`; the kernel execs it as process 1. This is the
     `userland/hello` boot: "The kernel's mockfs presents the ramdisk (this
     very file) as /sbin/launchd, so this runs as process 1"
     (`userland/src/hello.c`, header). mtkloader.c l.37 even warns
     "packfs will not mount a half image" — a torn image simply fails both
     mountroots.
4. `emmc_root=1` (mtk branch only): after the memory-map block,
   `IOFindBSDRoot` calls `hakios_mtk_emmc_root(root)`
   (`bsd/dev/hakios.mtk_emmc.c` in-tree; `kernel/bsd/dev/redwood_emmc.c` in
   the hakios-mt6768 device repo, l.418), which maps MSDC0, finds the GPT
   partition `xnusys`, registers `/dev/emmc0` and hands back its dev_t;
   rootName becomes `"emmc0"`; failure panics with a message naming the
   partition (mtk `xnu/hakios.patch`, IOKitBSDInit hunk). `rd=md0` stays on
   the command line because **libignition (Darwin) takes its "ramdisk" boot
   mode from it** — with `rd=emmc` it demanded a preboot volume and
   reboot-looped, and without `rd=md0` the sealed-root check panicked
   (hakios-mt6768 `docs/x6826b-emmc.md`, "How" section, runs 321/322).
   `redwood_emmc.c` works only because **LK left the card initialized in the
   transfer state**; the driver does plain PIO CMD17/CMD18+CMD12 reads
   (device-repo `redwood_emmc.c` l.26-31, l.60+: MSDC0 @ `0x11230000`,
   128 KB per command, read-only by construction).

### 1.3 What the images are (packfs is dead; long live APFS)

From mtk `docs/ru/notes.md` ("Только APFS, как на iPhone", ~l.1273-1300) and
`userland/build.sh` (main, l.1-70):

| image | what | size | role |
|---|---|---|---|
| `root.apfs` | 1 APFS container | **13.4 MB** | our init, test programs, `etc/rc`, launchd jobs; travels **in the payload next to the kernel as md1**, mounted on `/redwood` |
| `system.apfs` | 1 container | **2372 MB** | the root (md0): the part of Darwin userland 16.5 chosen by `sysimage/select-system.py`, the dyld shared cache, `src/stage0.c` as `/sbin/launchd` (real launchd at `/sbin/launchd.darwin`) |
| `flashboot.apfs` | 1 or 3 containers | 21 MB / 994 MB | boot volume for a flash-root boot (`stage0`, firmware, mount points), cryptexes optionally |
| `hello` | static Mach-O | 16 KB | mockfs boot; the ramdisk *is* process 1 |

Boot of full iOS (mtkloader flow, mtkloader.c + build.sh + stage0.c):

```
kernel: IOFindBSDRoot → md0 (system.apfs), md1 (root.apfs)
vfs_mountroot → apfs on md0 → exec /sbin/launchd  (= stage0.c)
stage0: mount("apfs", "/redwood", MNT_RDONLY, "/dev/md1"); exec /redwood/sbin/init
init.c: mounts /private/var (ramfs), runs etc/rc  (default rc.launchd)
rc.launchd: "exec /sbin/launchd.darwin"  → Darwin launchd → jobs (mkjobs.py)
```

**Minimum components for launchd + a shell** (verified from build.sh, mkjobs,
mk-jb.sh, notes):

- launchd: `system.apfs` is not optional for *Apple's* launchd — it needs the
  dyld shared cache and the Darwin files at real paths; `root.apfs` carries
  only our static init and the job lists.
- a shell: **Darwin userland 16.5 ships no shell at all** — "`/bin` is df and
  ps, and nothing else" (build.sh, RC_JOBS comment). The shell is
  `/var/jb/bin/sh` from the **Procursus rootless bootstrap** fetched by
  `tools/mk-jb.sh` (124 MB, kept out of git), packed into the system image as
  `/jb`, copied to `/private/var/jb` by init at boot (notes ~l.689-701). The
  practical interactive door upstream is OpenSSH from that prefix
  (`RC_JOBS=rc.jobs.ssh`); init runs rc lines itself (no shell needed:
  "words split on blanks, no quoting" — init.c run_command).
- `-s` / single-user is **not** a shell path here: XNU just passes `-s` as
  argv to launchd (`bsd/kern/kern_exec.c` l.7007: `boothowto & RB_SINGLE` →
  `init_args = "-s"`; set by `bsd/kern/bsd_init.c` l.1202 from the `-s`
  boot-arg). What stock iOS launchd does with `-s` is **UNVERIFIED**; on
  macOS it would fsck and spawn `/bin/sh`, which does not exist in this
  rootfs. Our `etc/rc` *is* the single-user mode of this port.

### 1.4 The phone-side delivery flows (for reference)

- redwood (SM7325, UEFI): `mkxnuimg.py` packs BootShim+UEFI+XNUP payload into
  an Android boot.img for `fastboot boot`; the big root is uploaded per
  session with `xl ramdisk userland/system.apfs` (loader places it at
  `RESIDENT_RD_OFFSET`), or lives on the phone's own flash
  (`root_apfs=ufs_darwin ufs=2 ufs_native=1`, notes ~l.1080).
- MT6768 (LK, no UEFI): `mtk/tools/gpt-carve.py` carves `xnusys` out of
  userdata; `system-flash.sh` dd's `system.apfs` into it from a rooted
  Android shell ("LK's fastboot cannot take a file this large");
  `boot-xnu.sh` writes a boot request into ramoops pmsg
  (`DARWIN-REDWOOD:BOOT-XNU`); `xnu-cycle.sh` flashes boot_a, runs XNU once,
  and pulls the log back from `/sys/fs/pstore/console-ramoops-0`.

---

## 2. Where panther stands right now (verified local state)

- Loader = `devices/panther/gsloader/stage2/m2ld.c` (M2 loader on the PE
  vehicle). It already:
  - finds the GSPE blob (manifest + raw XNU Mach-O) via in-image splice, FDT
    `/chosen/linux,initrd-start/end`, or a DRAM scan (l.687-771);
  - picks an XNU physical window `{img_end, +64 MB, 0x880000000}` with
    probe-based `window_ok()`; low windows are capped at `XNU_MEM_TOP
    0xf0000000` (keeps framebuffer `0xfac00000` and ramoops `0xfd3ff000` out)
    — l.60-64, l.843-859;
  - copies the kernel segments, builds an **Apple DT** and **boot_args**
    (l.893-920), registers the XNULDRST return stub, arms the watchdog,
    jumps.
- What m2ld does **not** do yet (the exact delta for option (a)):
  - `build_apple_dt()` (l.481-579) has **no `memory-map` node** — no
    `RAMDisk`/`RAMDisk1` properties;
  - the command line is `"debug=0x8 cpus=1 "` (l.919) — **no `rd=md0`**;
  - the GSPE format (`mkpe-manifest.py`, mirrored in m2ld.c l.313-325) has
    **one record: the kernel** (u32 `kernel_size`, cap `0x1200000` in
    `gspe_check` l.683). No ramdisk record.
- Delivery: `mkpe-bare.sh` — bare boot-image v4, kernel stream = full stock +
  m2ld@AEP (ABL tolerates ≤64 KB of kernel modification; bigger always dies —
  M2-PLAN "The ABL gate"), **ramdisk field = the GSPE blob, raw**
  (`RD_RAW=1` default "so the GSPE magic survives the loader's DRAM scan").
  Total proven: 33 MB (`panther-boot-bare-rd.img`). M2-PLAN: "ramdisk_size is
  unconstrained; multi-MB payloads fine" — **UNVERIFIED above the ~64 MB
  boot-image scale and against `fastboot` max-download on panther** (check
  `fastboot getvar max-download-size` before planning anything >100 MB).
- Where ABL puts the initramfs is being mapped right now by
  `stage2/m8rd.S` (band-encoded DRAM scanner for the lz4/GSPE magics);
  m2ld prefers the FDT `/chosen/linux,initrd-*` values (l.695-746).
- Stock-tree facts we will need (`devices/panther/dtb/FACTS.md`):
  UART0 `0x10A00000` (`earlycon=exynos4210`), kernel_loadaddr `0x10008000`,
  ramdisk_loadaddr `0x11000000`, dtb `0x11f00000`, RAM base `0x880000000`,
  `ufs@3c400000` compatible `google,ufshc`.
- Our kernel build: `DEVELOPMENT_ARM64_BCM2837` from this fork (pixel7 @
  4678bee), patch applied — RAMDisk/RAMDisk1 and rd=md0 handling confirmed
  present in the tree (section 1.2 cites the local file lines).

---

## 3. The three options, ranked by effort

### (c) First light — mockfs `hello`, debug flags, serial (hours)

The kernel already contains everything needed for a userspace proof; the
ramdisk content alone picks the path (section 1.2). Steps: build `hello`
(already at `userland/hello`, 16528 bytes, static, raw syscalls — verified
built on this machine today), carry it as the GSPE ramdisk record, declare
`RAMDisk`, pass `rd=md0`. Expected: `Hello from user space on Darwin! I am
process 1...` on whatever console exists; process 1 exiting panics the kernel
(hello.c: "Process 1 is not supposed to exit") — which is itself a clean
end-of-run marker.

Debug plumbing that costs nothing and pays for every later step:

- `debug` bits (`osfmk/kern/debug.h` l.513+): `DB_HALT 0x1` (wait for
  debugger at boot), `DB_NMI 0x4`, `DB_KPRT 0x8` (kprintf to console —
  upstream's default), `DB_KDB 0x10`. So `debug=0x14` = `DB_NMI|DB_KDB`;
  for readable panics upstream uses `debug=0x8 serial=3` (both loaders).
  `serial=3` routes the console to the UART — currently useless on panther
  until a gs201 UART console exists (below).
- Panic visibility without a shell: DEVELOPMENT kernels print the panic to
  the console and sit in the debugger loop (`osfmk/kern/debug.c` l.326+,
  l.394-400 boot-time behavior; l.1327+ dump/post-core bits). On panther the
  "console" today is the framebuffer (boot_args.video → `0xfac00000`) and
  the plog rings; M2-PLAN already queues "gs201 USI UART driver in the kernel
  fork" as the next milestone — that plus an `uart0` DT node with
  `boot-console` (as mtkloader.c l.947-953 does for its UART) gives real
  `debug=0x8 serial=3` output.
- A **serial recovery shell** without any Darwin dyld: write a mini-sh in the
  style of `init.c`/`hello.c` (static, raw syscalls, `userland/libmini`),
  open `/dev/console`, read/execute one line at a time (fork+exec from an
  APFS root once (a) lands, or fixed builtins before that). No upstream
  equivalent exists — **this would be new code, estimated a few hundred
  lines**; it is the honest "single-user mode" of this port (section 1.3:
  stock launchd gives us nothing here).

### (a) Ramdisk root through our GSPE container (days) — RECOMMENDED next

One new record in the GSPE blob, one copy loop, one DT node, one boot-arg.
Full step list in section 4. Key constraints:

- **Where the ramdisk must live, end to end:**
  1. *In the boot image*: the bare-v4 **ramdisk field**, raw (the proven
     channel; M2-PLAN: the kernel stream is closed to big payloads).
  2. *In DRAM after ABL*: wherever ABL leaves the initramfs
     (`linux,initrd-start/end` preferred, scan fallback — both already in
     m2ld). No alignment assumption: m2ld copies out of it.
  3. *Inside the XNU window*: copied to `kern_hi` (first 16K-aligned address
     above the kernel), **below the DT and boot_args, below
     `topOfKernelData`** — the static-mapping rule every upstream loader
     follows (loader.c l.2911, mtkloader.c l.2275). The window code must also
     keep excluding the payload source (`g_gspe_lo/hi`, m2ld.c l.652-657).
- **Sizes:** `hello` 16 KB; `root.apfs` 13.4 MB (fits with the ~16 MB kernel
  in the proven ~33 MB image with room to spare); `flashboot.apfs` 21 MB
  (same order). **`system.apfs` 2.37 GB does not fit** this channel, and
  would also wire most of the window if it did (MT6768 measured run 320:
  2.5 GB wired, 10-26 MB free, "System is unhealthy", jetsam —
  `docs/x6826b-emmc.md` table). So (a) delivers: hello → our init/rc on
  `root.apfs` as md0 → (later, once the kernel boots full iOS) the same
  mechanism with md0/md1 roles exactly as upstream.
- What (a) does *not* need: no kernel changes at all (RAMDisk/RAMDisk1,
  rd=md0, apfs, mockfs are all already in our build — section 1.2), no
  storage driver, no UFS.

### (b) eMMC/UFS root — a port of the redwood_emmc idea to gs201 (weeks)

- **Which controller:** Pixel 7 storage is UFS 3.1; the stock DTB has
  `ufs@3c400000`, compatible `google,ufshc` (gs201 UFSHCI-style host
  controller; strings dump of `devices/panther/dtb/panther-lga-base.dtb`).
  **UNVERIFIED**: the exact variant glue Linux uses for gs201 (Exynos/Tesla
  ufshcd glue, PHY/clock dependencies) — needs a look at the omarchy/
  AOSP `gs201` DTS + `ufshcd-*` driver before scoping.
- **What upstream's driver assumes — and why it does not transfer:**
  - `drivers/storage/hakios.ufs.c` (main) does not drive the controller at
    all: "There is no UFS driver here, and none is needed. **UEFI never
    exits** on this port: Qualcomm's own UFS driver (UFSDxe) has brought up
    the controller, its PHY, its clocks and power, and stays resident, and
    xnuloader keeps serving the kernel from core 0" — the kernel posts
    requests on a shared page (`ufs_shared_pa=` boot-arg; loader.c l.3149-
    3161 writes it into the command line).
  - `drivers/storage/hakios.ufshc.c` (kernel-side, `ufs_native=1`) also
    assumes a live controller: "no reset, no link startup, no UIC command,
    no interrupt enable, aggregation, clock or power setting" — it only
    swaps the UTP transfer request list into the controller for the duration
    of a run and swaps UEFI's back.
  - On panther **nothing is resident**: ABL hands a bare-metal loader, then
    our m2ld, then XNU; ABL's earlier stages leave the UFS controller in an
    undocumented state (Linux re-initializes it from scratch; **UNVERIFIED**
    what, if anything, survives for us).
- So (b) is one of:
  1. **Full kernel-side UFSHCI bring-up** (host reset, UIC/DME link startup,
     transfer/task lists, SCSI READ(10/16) UPIUs) — a real driver project;
     the honest comparison is not `redwood_emmc.c` (478 lines riding on LK's
     initialized card) but Linux's `ufshcd.c` scale. Read-only whitelist
     discipline as in `ufshc.c` applies cleanly.
  2. **m2ld as the storage server** (mimic xnoloader's core-0 role: m2ld
     brings the controller up before the jump, stays resident on a core
     XNU does not own, serves a shared page). This matches upstream's
     `ufs=2` design but is a new architecture for our loader chain (mtkloader
     never survives the jump). **UNVERIFIED** that ABL's state lets us own a
     second core cheaply; PSCI `smc` is in the DT (`FACTS.md`).
- Prize: the `xnusys`-style flow — `system.apfs` dd'd once into a carved
  partition (`tools/gpt-carve.py`, `system-flash.sh` patterns), read on
  demand, ~1 GB RAM freed, full iOS boots. Boot-args become
  `rd=md0 emmc_root=1`-equivalent (new `ufs_root=1` hook in IOFindBSDRoot —
  the mtk patch shows the exact 8-line shape), `root.packfs`→`root.apfs`
  stays md1.

---

## 4. Option (a) — concrete step list (smallest delta from today's loader)

Everything is in `devices/panther/gsloader/`. No shared-file kernel changes.

1. **GSPE v2 — add a ramdisk record.**
   - `mkpe-manifest.py`: bump magic to `GSPE02`, extend the header by 16
     bytes: `u64 ramdisk_off`, `u64 ramdisk_size` (offsets from blob start;
     `0` = none). Append the image bytes after the kernel.
   - `m2ld.c` `struct gspe_hdr` (l.313-325) gets the same two fields;
     `gspe_check()` (l.673-685) validates
     `ramdisk_off >= hdr_size + nsegs*32 + kernel_size`,
     `ramdisk_size <= 0x10000000` (sanity cap), and
     `g_gspe_hi` must now cover the ramdisk end (l.765-769).
   - `mkpe-bare.sh`: after `mkpe-manifest.py`, `cat` the chosen root image
     (`RD=` argument; default the freshly built `root.apfs` or `hello`) onto
     `gsspe.bin` before writing the ramdisk field; keep `RD_RAW=1`.
2. **m2ld: copy the ramdisk into the window.**
   - After the segment copy and the `text@` verify (l.866-891):
     `rd_pa = kern_hi` (already computed l.894);
     `rd_span = (ramdisk_size + 0x3fff) & ~0x3fff`;
     `memset`+`memcpy` from the GSPE record; log
     `"ramdisk " hex(rd_pa) " +0x"` hex(rd_span).
3. **m2ld: DT + boot_args move up past the ramdisk.**
   - `dt_pa = rd_pa + rd_span` (was `kern_hi`); `ba_pa`, `top` as now
     (l.897-900). Keep `topOfKernelData = top` covering everything — that is
     the static-mapping rule.
   - Room check: `span` (l.844) must add `rd_span` so `window_ok()` probes
     the whole range; `memsize` unchanged.
4. **m2ld: declare it.**
   - In `build_apple_dt()` (l.481-579), inside the root node next to
     `chosen` (mirroring loader.c l.3284-3298):
     ```
     dt_begin(&w, "memory-map");
     uint64_t rd_reg[2] = { rd_pa, rd_span };
     dt_prop(&w, "RAMDisk", rd_reg, sizeof(rd_reg));
     dt_end(&w);
     ```
     (Pass `rd_pa`/`rd_span` in as arguments, like `pram_pa` today.)
     Single image = `RAMDisk` = md0. Only if we later add the second image
     does `RAMDisk1` (md1) appear — upstream ordering: big = md0, small = md1.
5. **m2ld: boot-args.**
   - `cmdline` (l.919) → `"debug=0x8 cpus=1 rd=md0 "` when a ramdisk was
     loaded (keep the payload-free literal when not, so old images still
     boot). `serial=3` waits for the UART node/driver (option (c)).
6. **Cache maintenance** (l.929-935): the ramdisk bytes are read by the
   kernel through its static mapping — the copy target is inside the
   `m2ld_clean(pb, top - pb)` range already, since `top` moved past it; no
   extra call needed, but keep the plog note that the range grew.
7. **Build + first targets, in order:**
   1. `RD=hello`: expect the mockfs boot; success marker = the panic at
      process-1 exit (or `hello_wait=N` to hold the run open, hello.c).
   2. `RD=userland/root.apfs` (cross-build it: `userland/build.sh root.apfs`
      with `RC=rc.darwin` — runs Darwin binaries and halts; those binaries
      need the dyld cache, which root.apfs alone does not carry — so expect
      exec failures logged by init; **the run that matters is init itself
      printing its checks from md0**). A dyld-free variant: an `etc/rc` of
      only our static binaries (`hello`, init) — that is a full in-house
      userspace on the phone with zero Apple code.
   3. Add `RAMDisk1`/md1 + the stage0 flow when `system.apfs` gets a
      delivery path (i.e. after (b) or a resident-loader serving scheme).
8. **Verify chain end-to-end in the image** (extend `mkpe-bare.sh`'s verify
   block): GSPE02 magic, ramdisk_off/size match the appended bytes, and
   `m2ld` plog lines (`ramdisk 0x...`, `dt len`, `top`) survive in
   pmsg-ramoops-0 after the reset — same read-back dance as today.

Risks / open items (all **UNVERIFIED** until a run):

- ABL's initramfs placement/alignment for larger ramdisks (m8rd answers this
  — run it with the real payload before trusting the scan path; prefer
  `linux,initrd-*`).
- `fastboot getvar max-download-size` on this device bounds the total image.
- Whether ABL decompresses (or relocates) the ramdisk field for boot v4 —
  our raw (`RD_RAW=1`) + magic-scan design already tolerates either.
- m2ld's `XNU_MEM_TOP 0xf0000000` low-window cap: fine for (a); revisit if
  the high-bank window (`0x880000000`, 1 GB) is ever the only option.

---

## 5. Source index

Upstream `oosexgang/hakios-xnu-kernel` @ main `2631f5d` (unless noted):

- `xnuloader/loader.c` — l.18 PAYLOAD_BASE, l.29-34 RESIDENT_RD_OFFSET/
  RESERVE, l.2628-2648 payload entries (ramdisk/resident/rdres/cmdline),
  l.2908-2965 placement rules, l.3119-3143 boot-args assembly,
  l.3284-3298 memory-map/RAMDisk/RAMDisk1.
- `xnu/hakios.patch` — IOKitBSDInit hunk (rd=md fast wait, RAMDisk1).
- `xnu/README.md` — redwood branch, DEVELOPMENT_ARM64_BCM2837, driver map.
- `xnu/files/bsd/miscfs/apfs/*`, `bsd/miscfs/ramfs/` — the read-only APFS
  and writable ramfs drivers.
- `userland/build.sh` l.1-70 — root.apfs/system.apfs/flashboot.apfs roles,
  no-shell fact, rc handling; `userland/src/stage0.c`, `src/init.c`,
  `src/hello.c`; `userland/libmini/`.
- `sysimage/select-system.py` (what system.apfs contains), `sysimage/unpack.sh`.
- `tools/mk-jb.sh` — Procursus rootless bootstrap, /var/jb, the shell.
- `mkxnuimg.py`, `xnuloader/mkpayload.py` — XNUP container, boot.img packing.
- `drivers/storage/hakios.ufs.c` / `hakios.ufshc.c` / `conf` — the UFS
  assumptions quoted in section 3(b).

Upstream branch `mtk` @ `db08f63`:

- `mtk/loader/mtkloader.c` — l.34-35 SYSTEM_PA, l.120-137 XNU_ROOT_EMMC/
  boot-args, l.460-486 parse_payload, l.541-587 GPT, l.589-687 APFS-chain
  image load, l.868-886 memory-map node, l.2274-2336 run_xnu placement.
- `mtk/mt6768/drivers/storage/hakios.mtk_emmc.c` (= `bsd/dev/redwood_emmc.c`
  in-tree; the name mtkloader.c l.122 uses).
- `mtk/tools/{xnu-cycle,boot-xnu,system-flash,gpt-carve}.py/.sh`.
- `xnu/hakios.patch` — emmc_root hook in IOFindBSDRoot; md1-without-md0.
- `docs/ru/notes.md` — packfs→APFS transition, image sizes table, iPhone
  layout, `mkapfs.py` description; `mtk/README.md` — driver/boot-arg table.

`oosexgang/hakios-mt6768` (device repo):

- `kernel/bsd/dev/redwood_emmc.c` (478 lines; MSDC0 PIO, xnusys,
  `redwood_emmc_root()` l.418+, devfs nodes, sysctl).
- `docs/x6826b-emmc.md` — the md0-vs-eMMC memory numbers, runs 320-324,
  libignition/`rd=` facts (runs 321/322).
- `mtkloader/mtkloader.c` (device copy), `README.md`.

Our fork (pixel7 @ 4678bee):

- kernel tree `xnu-src/xnu-8796.121.2/`: `iokit/bsddev/IOKitBSDInit.cpp`
  l.689/753-781/787-829, `bsd/vfs/vfs_subr.c` l.1210+, `bsd/vfs/vfs_conf.c`
  l.258-287, `bsd/miscfs/mockfs/mockfs_vfsops.c` l.55+, `osfmk/kern/debug.h`
  l.513+, `osfmk/kern/debug.c` l.326/394-400, `bsd/kern/bsd_init.c` l.1202,
  `bsd/kern/kern_exec.c` l.7007-7066.
- `devices/panther/gsloader/`: `stage2/m2ld.c` (whole flow cited in
  sections 2/4), `stage2/m8rd.S`, `mkpe-manifest.py`, `mkpe-bare.sh`,
  `mkpe-image.sh`, `mkxnu-payload.sh`, `M2-PLAN.md`.
- `devices/panther/dtb/FACTS.md` — addresses, load addrs, UFS node,
  boot-image decode. `devices/panther/device.conf`, `metal.args`.
