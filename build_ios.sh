#!/bin/bash
# =============================================================================
# SiNiSistar2 -> iOS link test
#
# Links a Unity 2022.3.62f2 iOS app from:
#   libiPhone-lib.a        iOS engine, arm64 device, prebuilt by Unity
#   GameAssembly.dylib     the game logic, arm64, LC_BUILD_VERSION retagged to iOS
#   UnityNoExceptionsStub  supplies the one symbol the engine wants that the
#                          dylib does not export
#
# libil2cpp*.a is deliberately NOT linked: GameAssembly.dylib already exports
# the IL2CPP VM, and linking both would duplicate every il2cpp_* definition.
#
# Runs on macOS with Xcode. No Unity install, no Unity license.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Payload may sit beside the script (CI: unzipped flat) or in ./payload (local).
if [ -d "$ROOT/payload/Unity-iPhone.xcodeproj" ]; then
    PAYLOAD="$ROOT/payload"
else
    PAYLOAD="$ROOT"
fi
OUT="$ROOT/out"
LOG="$OUT/build.log"
SYMROOT="$OUT/build"

rm -rf "$OUT"
mkdir -p "$OUT" "$SYMROOT"

log() { echo "$@" | tee -a "$LOG"; }

log "=============================================================="
log " payload : $PAYLOAD"
log " out     : $OUT"
log "=============================================================="

log ""
log "== 1. inputs =="
fail=0
for f in \
    "$PAYLOAD/Unity-iPhone.xcodeproj/project.pbxproj" \
    "$PAYLOAD/Libraries/libiPhone-lib.a" \
    "$PAYLOAD/Libraries/baselib.a" \
    "$PAYLOAD/Frameworks/GameAssembly.dylib" \
    "$PAYLOAD/Classes/UnityNoExceptionsStub.c"
do
    if [ -e "$f" ]; then
        log "   ok   $(printf '%-42s' "${f#$PAYLOAD/}") $(du -h "$f" | cut -f1)"
    else
        log "   MISS $f"
        fail=1
    fi
done
[ "$fail" -eq 0 ] || { log "missing inputs"; exit 1; }

log ""
log "== 2. GameAssembly.dylib sanity =="
otool -hv "$PAYLOAD/Frameworks/GameAssembly.dylib" | sed -n '2,3p' | tee -a "$LOG"
log "   exported il2cpp_ symbols: $(nm -gU "$PAYLOAD/Frameworks/GameAssembly.dylib" 2>/dev/null | grep -c '_il2cpp_')"
log "   linked dylibs:"
otool -L "$PAYLOAD/Frameworks/GameAssembly.dylib" | tail -n +2 | sed 's/^/     /' | tee -a "$LOG"

log ""
log "== 3. stub archive for the GameAssembly slot =="
# The Xcode project's UnityFramework target links libGameAssembly.a out of
# BUILT_PRODUCTS_DIR. Unity would fill that with generated C++; we only need the
# single global the engine references, so we place a minimal archive there.
STUB="$OUT/stub"
mkdir -p "$STUB"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=11.0 -O2 \
    -c "$PAYLOAD/Classes/UnityNoExceptionsStub.c" -o "$STUB/UnityNoExceptionsStub.o" \
    || { log "stub compile failed"; exit 1; }
xcrun --sdk iphoneos libtool -static -o "$STUB/libGameAssembly.a" \
    "$STUB/UnityNoExceptionsStub.o" || { log "stub archive failed"; exit 1; }
mkdir -p "$SYMROOT/Release-iphoneos"
cp "$STUB/libGameAssembly.a" "$SYMROOT/Release-iphoneos/libGameAssembly.a"
log "   placed $SYMROOT/Release-iphoneos/libGameAssembly.a"

log ""
log "== 4. linking =="
cd "$PAYLOAD"

DYLIB="$PAYLOAD/Frameworks/GameAssembly.dylib"
ENGINE="$PAYLOAD/Libraries/libiPhone-lib.a"

# -force_load the engine: it is an archive of 1638 objects and the linker would
# otherwise drop everything not directly referenced from our own code.
LDFLAGS="-ObjC -Wl,-force_load,$ENGINE $DYLIB -Wl,-search_paths_first"

set -x
xcodebuild \
    -project Unity-iPhone.xcodeproj \
    -target UnityFramework \
    -configuration Release \
    -sdk iphoneos \
    -arch arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    SYMROOT="$SYMROOT" \
    OBJROOT="$OUT/obj" \
    VALIDATE_PRODUCT=NO \
    OTHER_LDFLAGS="$LDFLAGS" \
    2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set +x

log ""
if [ "$rc" -ne 0 ]; then
    log "================ LINK FAILED (exit $rc) ================"
    log "--- undefined / duplicate symbols ---"
    grep -iE 'undefined symbol|duplicate symbol|ld: |clang: error' "$LOG" | head -80
    exit "$rc"
fi

log "================ LINK OK ================"
find "$OUT" -name 'UnityFramework' -type f 2>/dev/null | while read -r f; do
    log "  $f  $(du -h "$f" | cut -f1)"
    lipo -info "$f" | sed 's/^/    /' | tee -a "$LOG"
    log "    undefined il2cpp left: $(nm -u "$f" 2>/dev/null | grep -c il2cpp || true)"
done
find "$OUT" -maxdepth 5 -name '*.app' 2>/dev/null | head
exit 0
