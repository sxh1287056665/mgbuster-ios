# -*- coding: utf-8 -*-
"""Neutralise the build-target guard inside SerializedFile::ReadMetadata.

Unity's SerializedFile::ReadMetadata<T> rejects any serialized file whose
target_platform is not the platform the player was built for:

    <false>  cmp w10, #9              ; kBuildTargetiOS
             b.ne  -> ErrorString("... created for another build target ...")
    <true>   movz w12, #0x900000
             cmp w10, w12
             b.ne  -> same error

The game data ships AssetBundles built for StandaloneOSX (2), so the iOS
player refuses them. NOP the two b.ne guards: execution then falls through
to the code path Unity itself takes when the check passes.

Same-length patch, so ar layout and relocations are untouched.

Usage: python3 patch_bundle_platform.py <libiPhone-lib.a> [--no-backup]
"""
import struct, sys, shutil, os

NOP = 0xd503201f
TARGET_MEMBER = "Runtime_Serialize_0_4ia5l.o"
PATCHES = [(0xaf08, 0x54003941), (0xbf9c, 0x54003b21)]


def parse_members(d):
    pos = 8
    out = []
    while pos + 60 <= len(d):
        hdr = d[pos:pos+60]
        if hdr[58:60] != b"\x60\x0a":
            break
        name = hdr[0:16].decode("latin1").strip()
        try:
            rawsize = int(hdr[48:58].decode("latin1").strip())
        except ValueError:
            break
        data_off = pos + 60
        if name.startswith("#1/"):
            nlen = int(name[3:])
            nm = d[data_off:data_off+nlen].rstrip(b"\x00").decode("latin1")
            real = data_off + nlen
            size = rawsize - nlen
        else:
            nm = name.rstrip("/")
            real = data_off
            size = rawsize
        out.append((nm, real, size))
        pos = data_off + rawsize
        if pos % 2:
            pos += 1
    return out


def main(path, backup=True):
    if not os.path.exists(path):
        print("FATAL: archive not found: %s" % path)
        return 1
    d = bytearray(open(path, "rb").read())
    print("archive %s  %d bytes" % (os.path.basename(path), len(d)))

    members = parse_members(d)
    hit = [m for m in members if m[0] == TARGET_MEMBER]
    if not hit:
        print("FATAL: member not found: %s" % TARGET_MEMBER)
        return 1
    nm, real, size = hit[0]
    print("member %s  off=0x%x size=%d" % (nm, real, size))

    m = d[real:real+size]
    ncmds = struct.unpack("<I", m[16:20])[0]
    p = 32
    text_off = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", m[p:p+8])
        if cmd == 0x19:
            nsects = struct.unpack("<I", m[p+64:p+68])[0]
            q = p + 72
            for _j in range(nsects):
                sn = bytes(m[q:q+16]).rstrip(b"\x00").decode("latin1")
                foff = struct.unpack("<I", m[q+48:q+52])[0]
                if sn == "__text":
                    text_off = foff
                q += 80
        p += cmdsize
    if text_off is None:
        print("FATAL: no __text section")
        return 1
    print("__text file offset 0x%x" % text_off)

    changed = 0
    for addr, expect in PATCHES:
        at = real + text_off + addr
        if at + 4 > len(d):
            print("FATAL: 0x%05x out of range" % addr)
            return 1
        cur = struct.unpack("<I", d[at:at+4])[0]
        if cur == NOP:
            print("0x%05x already nop, skipped" % addr)
            continue
        if cur != expect:
            print("FATAL: 0x%05x expected %08x, found %08x" % (addr, expect, cur))
            return 1
        d[at:at+4] = struct.pack("<I", NOP)
        print("0x%05x  %08x -> %08x  (b.ne -> nop)" % (addr, cur, NOP))
        changed += 1

    if changed == 0:
        print("nothing to do")
        return 0
    if backup:
        shutil.copy2(path, path + ".orig")
        print("backup -> %s.orig" % os.path.basename(path))
    open(path, "wb").write(bytes(d))
    print("wrote %d patch(es)" % changed)
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else "Libraries/libiPhone-lib.a"
    sys.exit(main(path, backup="--no-backup" not in sys.argv))
