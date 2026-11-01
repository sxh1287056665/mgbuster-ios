"""Neutralise the null dereference in PlayerLoadSettingsAndInput.

When the engine cannot load a built-in manager it takes an error path that
formats "Failed to load %s (internal index #%i)" - and reads the object's name
at +0x10 to fill in %s. If the object is null, that read faults before the
message is ever produced, so the crash log never says *which* manager failed.

Replacing the load with `mov x8, #0` leaves the format call intact: printf
renders the name as "(null)" and the internal index still prints. The index is
the datum we actually need.

Sequence patched (verified by shape, not by fixed offset):

    ldr  x8, [x8, #0x10]      f9400908
    stp  x8, x21, [sp]        a90057e8
    adrp x0, ...              "Failed to load %s (internal index #%i)"
    bl   Format

The function is located through the symbol table, so the patch survives any
shift in layout.
"""
import struct
import sys

FAILED_STRING = b"Failed to load %s (internal index #%i)"
SYMBOL_HINT = b"PlayerLoadSettingsAndInput"

ORIGINAL = 0xF9400908   # ldr x8, [x8, #0x10]
REPLACEMENT = 0xD2800008  # mov x8, #0
FOLLOW = 0xA90057E8     # stp x8, x21, [sp]


def main(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    if struct.unpack("<I", data[0:4])[0] != 0xFEEDFACF:
        sys.exit("not a 64-bit Mach-O: %s" % path)

    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    symtab = None
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", data[off + 24:off + 56])
            segs.append((vmaddr, vmsize, fileoff, filesize))
        elif cmd == 0x2:  # LC_SYMTAB
            symtab = struct.unpack("<IIII", data[off + 8:off + 24])
        off += cmdsize

    if symtab is None:
        sys.exit("no LC_SYMTAB - binary is stripped")

    def vm2file(vm):
        for vma, vsz, fo, fsz in segs:
            if vma <= vm < vma + vsz:
                return fo + (vm - vma)
        return None

    symoff, nsyms, stroff, strsize = symtab
    strtab = data[stroff:stroff + strsize]
    target = None
    for i in range(nsyms):
        p = symoff + i * 16
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack("<IBBHQ", data[p:p + 16])
        if n_value == 0:
            continue
        end = strtab.find(b"\0", n_strx)
        if SYMBOL_HINT in strtab[n_strx:end]:
            target = n_value
            print("  symbol PlayerLoadSettingsAndInput at vmaddr 0x%x" % target)
            break

    if target is None:
        sys.exit("PlayerLoadSettingsAndInput not found in the symbol table")

    # The format string tells us the function really is the one we think it is.
    if FAILED_STRING not in data:
        sys.exit("format string missing - wrong binary?")

    start = vm2file(target)
    if start is None:
        sys.exit("cannot map function address to a file offset")

    patched = 0
    for delta in range(0, 0x200, 4):
        p = start + delta
        word = struct.unpack("<I", data[p:p + 4])[0]
        nxt = struct.unpack("<I", data[p + 4:p + 8])[0]
        if word == ORIGINAL and nxt == FOLLOW:
            data[p:p + 4] = struct.pack("<I", REPLACEMENT)
            patched += 1
            print("  patched ldr x8,[x8,#0x10] -> mov x8,#0 at vmaddr 0x%x" % (target + delta))
            break

    if patched == 0:
        sys.exit("signature ldr/stp pair not found in the first 0x200 bytes")

    with open(path, "wb") as f:
        f.write(data)
    print("  wrote %s" % path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: patch_nullmanager.py <UnityFramework binary>")
    main(sys.argv[1])
