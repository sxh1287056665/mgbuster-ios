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
# Two build-time gaps in the Trampoline template are filled here:
#   UNITY_VERSION_VER/MAJ/MIN   Unity writes these into the pbxproj at build
#                               time; the template ships without them
#   Classes/Native/pch-cpp.hpp  IL2CPP-generated header, stubbed (we compile no
#                               generated C++)
#
# Runs on macOS with Xcode. No Unity install, no Unity license.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
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

# Unity version this payload was cut from.
UNITY_VER=2022
UNITY_MAJ=3
UNITY_MIN=62

log "=============================================================="
log " payload : $PAYLOAD"
log " unity   : ${UNITY_VER}.${UNITY_MAJ}.${UNITY_MIN}"
log "=============================================================="

log ""
log "== 1. inputs =="
fail=0
for f in \
    "$PAYLOAD/Unity-iPhone.xcodeproj/project.pbxproj" \
    "$PAYLOAD/Libraries/libiPhone-lib.a" \
    "$PAYLOAD/Libraries/baselib.a" \
    "$PAYLOAD/Frameworks/GameAssembly.dylib" \
    "$PAYLOAD/Classes/UnityNoExceptionsStub.c" \
    "$PAYLOAD/Classes/Native/pch-cpp.hpp"
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

log ""
log "== 3. stub archive for the GameAssembly slot =="
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
    UNITY_VERSION_VER="$UNITY_VER" \
    UNITY_VERSION_MAJ="$UNITY_MAJ" \
    UNITY_VERSION_MIN="$UNITY_MIN" \
    OTHER_LDFLAGS="$LDFLAGS" \
    2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set +x

log ""
if [ "$rc" -ne 0 ]; then
    log "================ BUILD FAILED (exit $rc) ================"
    log "--- compile errors ---"
    grep -E 'error:' "$LOG" | head -40
    log "--- linker errors ---"
    grep -iE 'undefined symbol|duplicate symbol|ld: ' "$LOG" | head -60
    exit "$rc"
fi

log "================ BUILD OK ================"
find "$OUT" -name 'UnityFramework' -type f 2>/dev/null | while read -r f; do
    log "  $f  $(du -h "$f" | cut -f1)"
    lipo -info "$f" | sed 's/^/    /' | tee -a "$LOG"
    log "    undefined il2cpp left: $(nm -u "$f" 2>/dev/null | grep -c il2cpp || true)"
done
find "$OUT" -maxdepth 5 -name '*.app' 2>/dev/null | head
exit 0
