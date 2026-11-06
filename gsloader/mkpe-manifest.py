#!/usr/bin/env python3
"""mkpe-manifest.py — XNU Mach-O (stdin) -> GSPE blob (stdout), diagnostics to stderr.

GSPE blob = 64-byte native-LE header + one record per LC_SEGMENT_64 + the raw
kernel bytes. Mirrors struct gspe_hdr in stage2/m2ld.c:

  char     magic[8]      "GSPE01\\0\\0"
  u32      hdr_size      64 (offset of the segment records)
  u32      nsegs
  u64      kvb           0xfffffff004000000 (boot_args.virtBase we will pass)
  u64      entry_va      LC_UNIXTHREAD pc
  u32      kernel_size
  u32      reserved
  u64      stub_slot_va  XNULDRST slot VA ("XNULDRST" magic in __TEXT), 0 if none
  { u64 vmaddr, vmsize, fileoff, filesize } x nsegs
  u8[kernel_size]

stdio-only on purpose: no argv paths, no subprocess, no filesystem writes.
"""
import struct
import sys

KVB = 0xfffffff004000000
TEXT_BASE = 0xfffffff007004000   # first __TEXT vmaddr for this kernel family


def die(msg):
    sys.stderr.write("mkpe-manifest: %s\n" % msg)
    sys.exit(1)


def main():
    d = sys.stdin.buffer.read()
    if len(d) < 64:
        die("input too small for a Mach-O")
    magic = struct.unpack_from("<I", d, 0)[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        nfat = struct.unpack_from(">I", d, 4)[0]
        off = None
        for i in range(nfat):
            cpu, _s, o, _sz, _a = struct.unpack_from(">5I", d, 8 + 20 * i)
            if cpu == 0x0100000C:
                off = o
                break
        if off is None:
            die("fat image without an arm64 slice")
        d = d[off:]
        magic = struct.unpack_from("<I", d, 0)[0]
    if magic != 0xFEEDFACF:
        die("not a 64-bit arm64 Mach-O (magic 0x%08x)" % magic)
    if struct.unpack_from("<I", d, 4)[0] != 0x0100000C:
        die("cputype is not arm64")

    ncmds = struct.unpack_from("<I", d, 16)[0]
    segs, entry = [], None
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", d, off)
        if cmd == 0x19:                          # LC_SEGMENT_64
            segs.append(struct.unpack_from("<4Q", d, off + 24))
        elif cmd == 0x05:                        # LC_UNIXTHREAD
            entry = struct.unpack_from("<Q", d, off + 16 + 32 * 8)[0]
        off += cmdsize
    if entry is None:
        die("no LC_UNIXTHREAD")

    live = [s for s in segs if s[1]]
    vm_lo = min(s[0] for s in live)
    vm_hi = max(s[0] + s[1] for s in live)
    if vm_lo != TEXT_BASE:
        sys.stderr.write("mkpe-manifest: NOTE first segment 0x%x != 0x%x\n"
                         % (vm_lo, TEXT_BASE))
    if vm_lo < KVB:
        die("first segment 0x%x below virtBase 0x%x" % (vm_lo, KVB))
    if not (vm_lo <= entry < vm_hi):
        die("entry 0x%x outside segments [0x%x, 0x%x)" % (entry, vm_lo, vm_hi))

    idx = d.find(b"XNULDRST")           # slot sits in __TEXT_EXEC bytes
    stub = TEXT_BASE + idx if 0 <= idx < 0x1200000 else 0

    out = bytearray(b"GSPE01\0\0")
    out += struct.pack("<II", 48, len(segs))       # hdr_size = offsetof(segs)
    out += struct.pack("<QQ", KVB, entry)
    out += struct.pack("<II", len(d), 0)
    out += struct.pack("<Q", stub)
    assert len(out) == 48
    for s in segs:
        out += struct.pack("<4Q", *s)
    out += d
    sys.stdout.buffer.write(bytes(out))

    sys.stderr.write(
        "mkpe-manifest: kernel=%d segs=%d entry=0x%x vm=[0x%x,0x%x) "
        "span_from_kvb=0x%x stub_slot=0x%x\n"
        % (len(d), len(segs), entry, vm_lo, vm_hi, vm_hi - KVB, stub))


if __name__ == "__main__":
    main()
