#!/bin/bash
# =============================================================================
# SiNiSistar2 -> iOS link test
#
# Links a Unity 2022.3.62f2 iOS app from:
#   libiPhone-lib.a        iOS engine, arm64 device, prebuilt by Unity
#   GameAssembly.dylib     the game logic, arm64, LC_BUILD_VERSION retagged to iOS
#   Libraries/*.cpp        Unity's two trampoline-side translation units
#                          (Il2CppOptions.cpp defines Unity_il2cppNoExceptions)
#
# libil2cpp*.a is deliberately NOT linked: GameAssembly.dylib already exports
# the IL2CPP VM, and linking both would duplicate every il2cpp_* definition.
#
# Two build-time gaps in the Trampoline template are filled here:
#   UNITY_VERSION_VER/MAJ/MIN   Unity writes these into the pbxproj at build
#                               time; the template ships without them, and they
#                               are checked by the C preprocessor
#   Classes/pch-cpp.hpp         IL2CPP-generated header, stubbed (we compile no
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
    "$PAYLOAD/Libraries/Il2CppOptions.cpp" \
    "$PAYLOAD/Libraries/RegisterFeatures.cpp" \
    "$PAYLOAD/Frameworks/GameAssembly.dylib" \
    "$PAYLOAD/Classes/pch-cpp.hpp"
do
    if [ -e "$f" ]; then
        log "   ok   $(printf '%-40s' "${f#$PAYLOAD/}") $(du -h "$f" | cut -f1)"
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
log "   Unity_il2cppNoExceptions defined by: Libraries/Il2CppOptions.cpp (function)"

log ""
log "== 3. stub archive for the GameAssembly slot =="
# The UnityFramework target links libGameAssembly.a out of BUILT_PRODUCTS_DIR.
# Unity fills that with generated C++; we compile none. The archive still has to
# be a well-formed one - ld rejects a zero-byte file - so it carries a single
# placeholder object.
STUB="$OUT/stub"
mkdir -p "$STUB" "$SYMROOT/Release-iphoneos"
cat > "$STUB/placeholder.c" <<'EOF'
/* Stands in for the IL2CPP-generated translation units Unity would place in
   libGameAssembly.a. The real game code is linked from GameAssembly.dylib. */
int __unity_ios_link_placeholder = 0;
EOF
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=11.0 -O2 \
    -c "$STUB/placeholder.c" -o "$STUB/placeholder.o" \
    || { log "placeholder compile failed"; exit 1; }
xcrun --sdk iphoneos libtool -static -o "$STUB/libGameAssembly.a" "$STUB/placeholder.o" \
    || { log "placeholder archive failed"; exit 1; }
cp "$STUB/libGameAssembly.a" "$SYMROOT/Release-iphoneos/libGameAssembly.a"
log "   placed $SYMROOT/Release-iphoneos/libGameAssembly.a ($(du -h "$STUB/libGameAssembly.a" | cut -f1))"

log ""
log "== 3b. generated-registration stubs =="
# The engine references three functions that Unity generates into
# libGameAssembly.a. We compile none, so they are supplied here and archived
# into their own library. They are compiled separately rather than added to the
# Xcode target's Sources phase to keep project.pbxproj untouched.
xcrun --sdk iphoneos clang++ -arch arm64 -mios-version-min=11.0 -O2 -std=c++17 \
    -c "$PAYLOAD/Libraries/UnityGeneratedStubs.cpp" -o "$STUB/UnityGeneratedStubs.o" \
    || { log "generated-stub compile failed"; exit 1; }
xcrun --sdk iphoneos libtool -static -o "$STUB/libUnityGeneratedStubs.a" \
    "$STUB/UnityGeneratedStubs.o" || { log "generated-stub archive failed"; exit 1; }
log "   libUnityGeneratedStubs.a $(du -h "$STUB/libUnityGeneratedStubs.a" | cut -f1)"
log "   provides: RegisterStaticallyLinkedModulesGranular (C),"
log "             RegisterAllClasses / RegisterAllStrippedInternalCalls (C++)"

log ""
log "== 4. linking =="
cd "$PAYLOAD"

DYLIB="$PAYLOAD/Frameworks/GameAssembly.dylib"
ENGINE="$PAYLOAD/Libraries/libiPhone-lib.a"
GENSTUB="$STUB/libUnityGeneratedStubs.a"
LDFLAGS="-ObjC -Wl,-force_load,$ENGINE $GENSTUB $DYLIB -Wl,-search_paths_first"

# Unity writes UNITY_VERSION_* into the pbxproj at build time; the Trampoline
# template ships with zero occurrences. They are checked by the C preprocessor
# (UnityTrampolineConfigure.h:8), so they must go into GCC_PREPROCESSOR_DEFINITIONS
# as -D style defines - passing them as bare build settings does nothing.
DEFINES="\$(inherited) UNITY_VERSION_VER=$UNITY_VER UNITY_VERSION_MAJ=$UNITY_MAJ UNITY_VERSION_MIN=$UNITY_MIN"

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
    GCC_PREPROCESSOR_DEFINITIONS="$DEFINES" \
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
