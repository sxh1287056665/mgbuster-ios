"""Shorten the engine's own version constant so it matches the game's data.

The iOS engine we link against is the China edition and stamps itself
2022.3.62f2c1. The game ships data from an international macOS build stamped
2022.3.62f2, and Unity rejects the file on that difference:

    Invalid serialized file version. Expected version: 2022.3.62f2c1.
    Actual version: 2022.3.62f2.

Lengthening the data's stamp is the other way to reconcile them, but that grows
the serialized header and shifts every object offset, which is far more
invasive than it looks. Shortening the engine's constant costs nothing: the
string simply terminates two bytes earlier and the following constants keep
their addresses.

The constant is identified by its neighbour in the string pool rather than by a
hardcoded offset, so the patch survives any change in binary layout. Only the
plain version string is touched - the "<version>_<revision>" and
"<version> (<revision>)" forms used for logging keep their original text.
"""
import sys

ORIGINAL = b"2022.3.62f2c1"
SHORTENED = b"2022.3.62f2"
PRECEDING = b"Unity Technologies\0"


def main(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    patched = 0
    search_from = 0
    while True:
        idx = data.find(ORIGINAL, search_from)
        if idx < 0:
            break
        search_from = idx + 1

        if idx < len(PRECEDING) or bytes(data[idx - len(PRECEDING):idx]) != PRECEDING:
            continue

        # Terminate two characters early; the trailing "c1" becomes padding.
        data[idx:idx + len(ORIGINAL)] = SHORTENED + b"\0" * (len(ORIGINAL) - len(SHORTENED))
        patched += 1
        print("  engine version constant at file offset 0x%x: %s -> %s"
              % (idx, ORIGINAL.decode(), SHORTENED.decode()))
        break

    if patched == 0:
        sys.exit("version constant not found next to %r" % PRECEDING)

    with open(path, "wb") as f:
        f.write(data)
    print("  wrote %s" % path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: patch_engine_version.py <UnityFramework binary>")
    main(sys.argv[1])
