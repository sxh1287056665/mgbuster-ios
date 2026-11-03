#!/usr/bin/env python3
"""Rewrite DecompressNativeTexture's entry into a branch to our decoder.

The iOS player carries only ETC2/EAC and ASTC decompressors.  Its dispatcher
switches on GraphicsFormat over 0x6f..0x96, so DXT1 (97), DXT5 (101) and BC7
(109) fall outside the table and land on the failure path that logs
"Failed to decompress".  gbpad_texdec.cpp supplies those three formats; this
script wires the engine to it.

Both the dispatcher and our decoder live in UnityFramework, so an ordinary
PC-relative `b` is enough -- no new segment, no dylib, no interpose.
"""

import struct
import sys

# Symbol names as they appear in UnityFramework's LC_SYMTAB.
DISPATCHER = "__Z23DecompressNativeTexture14GraphicsFormatS_iiPKjiiPj"
DECODER = "_gbpad_decompress_native"

LC_SYMTAB = 0x2
MH_MAGIC_64 = 0xFEEDFACF


def parse(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    if struct.unpack("<I", data[:4])[0] != MH_MAGIC_64:
        raise SystemExit("not a 64-bit Mach-O: %s" % path)
    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    symtab = None
    segments = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == LC_SYMTAB:
            symtab = struct.unpack("<IIII", data[off + 8:off + 24])
        elif cmd == 0x19:  # LC_SEGMENT_64
            name = data[off + 8:off + 24].rstrip(b"\0").decode("latin1")
            vmaddr, vmsize, fileoff, filesize = struct.unpack(
                "<QQQQ", data[off + 24:off + 56])
            segments.append((name, vmaddr, vmsize, fileoff, filesize))
        off += cmdsize
    if symtab is None:
        raise SystemExit("no LC_SYMTAB")
    return data, symtab, segments


def symbols(data, symtab):
    symoff, nsyms, stroff, strsize = symtab
    strtab = bytes(data[stroff:stroff + strsize])
    out = {}
    for i in range(nsyms):
        p = symoff + i * 16
        n_strx, _n_type, _n_sect, _n_desc, n_value = struct.unpack(
            "<IBBHQ", data[p:p + 16])
        if n_strx == 0:
            continue
        end = strtab.find(b"\0", n_strx)
        if end < 0:
            continue
        out.setdefault(strtab[n_strx:end].decode("latin1"), n_value)
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: patch_texdec.py <UnityFramework>")
    path = sys.argv[1]
    data, symtab, segments = parse(path)
    syms = symbols(data, symtab)

    if DISPATCHER not in syms:
        raise SystemExit("FAIL: %s not found" % DISPATCHER)
    if DECODER not in syms:
        raise SystemExit(
            "FAIL: %s not found -- is gbpad_texdec.cpp linked into "
            "UnityFramework?" % DECODER)

    target = syms[DISPATCHER]
    decoder = syms[DECODER]

    # __TEXT is vmaddr 0 / fileoff 0, so a code address is also a file offset.
    text = [s for s in segments if s[0] == "__TEXT"]
    if not text or text[0][1] != 0 or text[0][3] != 0:
        raise SystemExit("FAIL: __TEXT is not at vmaddr 0; offsets would differ")

    delta = decoder - target
    if delta % 4:
        raise SystemExit("FAIL: unaligned branch target")
    if not (-(1 << 27) <= delta < (1 << 27)):
        raise SystemExit("FAIL: branch out of range (%d)" % delta)

    insn = 0x14000000 | ((delta >> 2) & 0x03FFFFFF)
    old = struct.unpack("<I", data[target:target + 4])[0]

    if old == insn:
        print("already patched: 0x%x -> 0x%x" % (target, decoder))
        return 0

    # Sanity: the entry must still be the STP that opens the prologue, so we
    # never clobber something that has already been rewritten.
    if (old & 0xFFC00000) == 0x14000000:
        raise SystemExit(
            "FAIL: 0x%x already branches elsewhere (0x%08x)" % (target, old))

    struct.pack_into("<I", data, target, insn)
    with open(path, "wb") as f:
        f.write(data)

    check = struct.unpack("<I", data[target:target + 4])[0]
    if check != insn:
        raise SystemExit("FAIL: write did not stick")
    print("patched 0x%x: 0x%08x -> 0x%08x  (b 0x%x, delta %+d)"
          % (target, old, insn, decoder, delta))
    return 0


if __name__ == "__main__":
    sys.exit(main())
