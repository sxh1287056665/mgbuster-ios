#!/usr/bin/env python3
"""
Remove the code signature from a 64-bit Mach-O without corrupting __LINKEDIT.

codesign --remove-signature drops the LC_CODE_SIGNATURE blob but leaves the
__LINKEDIT segment claiming the old size, which makes install_name_tool refuse
the file ("link edit information does not fill the __LINKEDIT segment"). This
does the surgery properly:

  1. delete the LC_CODE_SIGNATURE load command (ncmds - 1, sizeofcmds - 16,
     commands packed back together) - NOT just zero its dataoff/datasize
  2. shrink __LINKEDIT filesize/vmsize to what remains
  3. truncate the file at the old dataoff

Step 1 has to delete the command. A load command left behind as
LC_CODE_SIGNATURE{dataoff=0, datasize=0} is fatal for every ldid-derived
signer, which is what TrollStore uses on device:

  ldid.cpp:1476  size = Swap(signature->dataoff);     -> size = 0
  ldid.cpp:1483  _assert(stroff + strsize <= size);   -> 62074682 <= 0 fails
  ldid.cpp:1390  pointer = base + dataoff;            -> SuperBlob read at the
                 (SuperBlob *)pointer; Swap(super->count) -> reads the Mach-O
                 magic 0xFEEDFACF as a blob count and walks off the buffer

ldid then dies with "ldid.cpp(1483): _assert(): end <= size" (and/or a segfault)
and returns non-zero, which surfaces as TrollStore install error 175
"app signing failed, ldid returned a non-zero status".

Result after this script: a well-formed unsigned Mach-O that codesign, ldid,
Sideloadly and install_name_tool all accept.
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

    if sig_cmd_off is None:
        print("%s: no LC_CODE_SIGNATURE, nothing to do" % path)
        return 0

    if off != 32 + sizeofcmds:
        sys.exit("%s: load commands end at %d, header says %d - refusing"
                 % (path, off, 32 + sizeofcmds))

    total = len(data)
    print("%s" % path)
    print("  file size        : %d" % total)
    print("  LC_CODE_SIGNATURE: dataoff=%d datasize=%d (ends at %d)" % (sig_off, sig_size, sig_off + sig_size))
    if sig_off + sig_size != total:
        print("  WARNING: signature does not end at EOF; truncating anyway would drop data")

    if linkedit:
        vmaddr, vmsize, fileoff, filesize = linkedit
        print("  __LINKEDIT       : fileoff=%d filesize=%d vmsize=%d" % (fileoff, filesize, vmsize))

    # 1. delete the load command and pack the remaining ones back together
    end_of_cmds = 32 + sizeofcmds
    tail = bytes(data[sig_cmd_off + 16:end_of_cmds])
    data[sig_cmd_off:sig_cmd_off + len(tail)] = tail
    data[end_of_cmds - 16:end_of_cmds] = b"\0" * 16
    struct.pack_into("<II", data, 16, ncmds - 1, sizeofcmds - 16)
    print("  ncmds/sizeofcmds : %d/%d -> %d/%d" % (ncmds, sizeofcmds, ncmds - 1, sizeofcmds - 16))

    # 2. shrink __LINKEDIT so it ends exactly at the new EOF
    if linkedit:
        vmaddr, vmsize, fileoff, filesize = linkedit
        new_filesize = sig_off - fileoff
        new_vmsize = (new_filesize + 0x3FFF) & ~0x3FFF  # round up to 16 KB pages
        struct.pack_into("<QQQQ", data, linkedit_cmd_off + 24, vmaddr, new_vmsize, fileoff, new_filesize)
        print("  __LINKEDIT new   : filesize=%d vmsize=%d" % (new_filesize, new_vmsize))

    # 3. drop the signature blob past the end of the segments
    del data[sig_off:]
    with open(path, "wb") as f:
        f.write(data)

    # 4. re-verify what we just wrote
    ncmds2, sizeofcmds2 = struct.unpack("<II", data[16:24])
    off2 = 32
    seen = []
    for _ in range(ncmds2):
        cmd, cmdsize = struct.unpack("<II", data[off2:off2 + 8])
        seen.append(cmd)
        off2 += cmdsize
    assert off2 == 32 + sizeofcmds2, "load command packing broke"
    assert LC_CODE_SIGNATURE not in seen, "signature command survived"
    print("  -> %d bytes, signature removed (ncmds=%d, commands end %d)" % (len(data), ncmds2, off2))
    return sig_size


if __name__ == "__main__":
    for p in sys.argv[1:]:
        strip(p)