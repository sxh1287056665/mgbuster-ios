#!/usr/bin/env python3
"""
Remove the code signature from a 64-bit Mach-O without corrupting __LINKEDIT.

codesign --remove-signature drops the LC_CODE_SIGNATURE blob but leaves the
__LINKEDIT segment claiming the old size, which makes install_name_tool refuse
the file ("link edit information does not fill the __LINKEDIT segment"). This
does the surgery properly:

  1. locate LC_CODE_SIGNATURE and __LINKEDIT
  2. zero the signature command's dataoff/datasize
  3. shrink __LINKEDIT filesize/vmsize to what remains
  4. truncate the file at the old dataoff

Result: a well-formed unsigned Mach-O that codesign / ldid / install_name_tool
all accept.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D


def strip(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic = bytes(data[:4])
    if magic != b"\xcf\xfa\xed\xfe":
        sys.exit("%s: not a 64-bit little-endian Mach-O (magic %s)" % (path, magic.hex()))

    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack("<IIIIII", data[4:28])

    off = 32
    sig_off = sig_size = None
    sig_cmd_off = None
    linkedit = None
    linkedit_cmd_off = None

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == LC_CODE_SIGNATURE:
            sig_cmd_off = off
            sig_off, sig_size = struct.unpack("<II", data[off + 8:off + 16])
        elif cmd == LC_SEGMENT_64:
            segname = bytes(data[off + 8:off + 24]).split(b"\0")[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", data[off + 24:off + 56])
            if segname == "__LINKEDIT":
                linkedit = (vmaddr, vmsize, fileoff, filesize)
                linkedit_cmd_off = off
        off += cmdsize

    if sig_off is None:
        print("%s: no LC_CODE_SIGNATURE, nothing to do" % path)
        return 0

    total = len(data)
    print("%s" % path)
    print("  file size        : %d" % total)
    print("  LC_CODE_SIGNATURE: dataoff=%d datasize=%d (ends at %d)" % (sig_off, sig_size, sig_off + sig_size))
    if sig_off + sig_size != total:
        print("  WARNING: signature does not end at EOF; truncating anyway would drop data")

    if linkedit:
        vmaddr, vmsize, fileoff, filesize = linkedit
        print("  __LINKEDIT       : fileoff=%d filesize=%d vmsize=%d" % (fileoff, filesize, vmsize))

    # 1. zero the signature command
    struct.pack_into("<II", data, sig_cmd_off + 8, 0, 0)

    # 2. shrink __LINKEDIT so it ends exactly at the new EOF
    if linkedit:
        vmaddr, vmsize, fileoff, filesize = linkedit
        new_filesize = sig_off - fileoff
        new_vmsize = (new_filesize + 0x3FFF) & ~0x3FFF  # round up to 16 KB pages
        struct.pack_into("<QQQQ", data, linkedit_cmd_off + 24, vmaddr, new_vmsize, fileoff, new_filesize)
        print("  __LINKEDIT new   : filesize=%d vmsize=%d" % (new_filesize, new_vmsize))

    # 3. truncate
    del data[sig_off:]
    with open(path, "wb") as f:
        f.write(data)

    print("  -> %d bytes, signature removed" % len(data))
    return sig_size


if __name__ == "__main__":
    for p in sys.argv[1:]:
        strip(p)
