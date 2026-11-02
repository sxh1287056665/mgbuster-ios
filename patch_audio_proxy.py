# -*- coding: utf-8 -*-
"""Neutralise AudioSettings::MobileProxy::InvokeOnMuteStateChanged in UnityFramework.

The iOS engine calls this managed method during startUnity: to notify the
C# layer of the mute state. The managed method lives in
UnityEngine.AudioSettings/Mobile, which is a mobile-only class that the
macOS il2cpp build stripped entirely, so LookupMethod returns null and the
caller dereferences it:

    bl   GetMethod(...)        ; x0 = null
    ldr  x1, [x0, #0x48]       ; SIGSEGV

Turn the function's prologue into a bare `ret`: it is a pure notification
with no return value, so skipping it lets startUnity: proceed.

Locate the function through the Mach-O symbol table, never by a fixed
offset, because a fresh CI build may lay the binary out differently.

Usage: python3 patch_audio_proxy.py <UnityFramework> [--no-backup]
"""
import struct, sys, shutil, os

SYMBOL = (b"__ZN9Scripting11UnityEngine13AudioSettings11MobileProxy"
          b"24InvokeOnMuteStateChangedEbP21ScriptingExceptionPtr")
RET = 0xd65f03c0


def macho_sections_and_symtab(d):
    ncmds = struct.unpack("<I", d[16:20])[0]
    off = 32
    symtab = None
    segs = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack("<II", d[off:off+8])
        if cmd == 0x2:
            symtab = struct.unpack("<IIII", d[off+8:off+24])
        elif cmd == 0x19:
            name = d[off+8:off+24].rstrip(b"\x00").decode("latin1")
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", d[off+24:off+56])
            segs.append((name, vmaddr, vmsize, fileoff, filesize))
        off += sz
    return segs, symtab


def find_symbol(d, symtab, target):
    symoff, nsyms, stroff, strsize = symtab
    for i in range(nsyms):
        q = symoff + i * 16
        n_strx = struct.unpack("<I", d[q:q+4])[0]
        n_value = struct.unpack("<Q", d[q+8:q+16])[0]
        e = d.index(b"\x00", stroff + n_strx)
        if d[stroff + n_strx:e] == target.rstrip(b"\x00"):
            return n_value
    return None


def vm_to_file(segs, vm):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= vm < vmaddr + vmsize:
            return fileoff + (vm - vmaddr)
    return None


def main(path, backup=True):
    d = bytearray(open(path, "rb").read())
    print("binary %s  %d bytes" % (os.path.basename(path), len(d)))
    segs, symtab = macho_sections_and_symtab(d)
    if symtab is None:
        print("FATAL: no LC_SYMTAB")
        return 1
    vm = find_symbol(d, symtab, SYMBOL)
    if vm is None:
        print("FATAL: symbol not found")
        return 1
    at = vm_to_file(segs, vm)
    if at is None:
        print("FATAL: cannot map vm 0x%x to file offset" % vm)
        return 1
    cur = struct.unpack("<I", d[at:at+4])[0]
    print("symbol vm=0x%x -> file 0x%x, current opcode %08x" % (vm, at, cur))
    if cur == RET:
        print("already ret, nothing to do")
        return 0
    # sanity: prologue should be a `sub sp, sp, #imm` (0xD10xxxxx) or stp
    if (cur & 0xFFC00000) != 0xD1000000 and (cur & 0x7FC00000) != 0x29000000:
        print("FATAL: unexpected prologue %08x, refusing to patch" % cur)
        return 1
    d[at:at+4] = struct.pack("<I", RET)
    if backup:
        shutil.copy2(path, path + ".orig")
    open(path, "wb").write(bytes(d))
    print("patched 0x%x: %08x -> %08x (prologue -> ret)" % (at, cur, RET))
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    p = args[0] if args else "UnityFramework"
    sys.exit(main(p, backup="--no-backup" not in sys.argv))
