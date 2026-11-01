#!/bin/bash
# =============================================================================
# SiNiSistar2 -> iOS app package
#
# Builds an installable .app from the Unity 2022.3.62f2 iOS Trampoline, then
# wraps it as an unsigned .ipa. No Unity install, no Unity license.
#
#   libiPhone-lib.a        iOS engine, arm64 device, prebuilt by Unity
#   GameAssembly.dylib     the game logic, arm64, LC_BUILD_VERSION retagged to iOS
#   Libraries/*.cpp        Unity's trampoline-side translation units
#   Classes/pch-cpp.hpp    stand-in for the IL2CPP-generated precompiled header
#   Data/                  game data, copied as a folder reference
#
# libil2cpp*.a is deliberately NOT linked: GameAssembly.dylib already exports
# the IL2CPP VM, and linking both would duplicate every il2cpp_* definition.
#
# Signing is out of scope here: CODE_SIGNING_ALLOWED=NO produces an unsigned
# binary. Sign the .app before installing on a device.
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

APP_NAME="SiNiSistar2"
BUNDLE_ID="com.jskf95zone.sinisistar2"

UNITY_VER=2022
UNITY_MAJ=3
UNITY_MIN=62

rm -rf "$OUT"
mkdir -p "$OUT" "$SYMROOT"
log() { echo "$@" | tee -a "$LOG"; }

log "=============================================================="
log " payload : $PAYLOAD"
log " app     : $APP_NAME  ($BUNDLE_ID)"
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
    "$PAYLOAD/Libraries/UnityGeneratedStubs.cpp" \
    "$PAYLOAD/Frameworks/GameAssembly.dylib" \
    "$PAYLOAD/Classes/pch-cpp.hpp" \
    "$PAYLOAD/Info.plist" \
    "$PAYLOAD/Data/Managed/Metadata/global-metadata.dat"
do
    if [ -e "$f" ]; then
        log "   ok   $(printf '%-44s' "${f#$PAYLOAD/}") $(du -h "$f" 2>/dev/null | cut -f1)"
    else
        log "   MISS $f"
        fail=1
    fi
done
[ "$fail" -eq 0 ] || { log "missing inputs"; exit 1; }
log "   Data/ total: $(du -sh "$PAYLOAD/Data" | cut -f1), $(find "$PAYLOAD/Data" -type f | wc -l | tr -d ' ') files"

log ""
log "== 2. GameAssembly.dylib sanity =="
otool -hv "$PAYLOAD/Frameworks/GameAssembly.dylib" | sed -n '2,3p' | tee -a "$LOG"
log "   exported il2cpp_ symbols: $(nm -gU "$PAYLOAD/Frameworks/GameAssembly.dylib" 2>/dev/null | grep -c '_il2cpp_')"

log ""
log "== 3. auxiliary archives =="
STUB="$OUT/stub"
mkdir -p "$STUB" "$SYMROOT/Release-iphoneos"

# 3a. placeholder for the slot Unity would fill with generated C++
cat > "$STUB/placeholder.c" <<'EOF'
/* Stands in for the IL2CPP-generated translation units Unity would place in
   libGameAssembly.a. The real game code is linked from GameAssembly.dylib. */
int __unity_ios_link_placeholder = 0;
EOF
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=11.0 -O2 \
    -c "$STUB/placeholder.c" -o "$STUB/placeholder.o" || { log "placeholder compile failed"; exit 1; }
xcrun --sdk iphoneos libtool -static -o "$STUB/libGameAssembly.a" "$STUB/placeholder.o" \
    || { log "placeholder archive failed"; exit 1; }
cp "$STUB/libGameAssembly.a" "$SYMROOT/Release-iphoneos/libGameAssembly.a"
log "   libGameAssembly.a        $(du -h "$STUB/libGameAssembly.a" | cut -f1)  (placeholder)"

# 3b. the three registration hooks Unity generates into libGameAssembly.a
xcrun --sdk iphoneos clang++ -arch arm64 -mios-version-min=11.0 -O2 -std=c++17 \
    -c "$PAYLOAD/Libraries/UnityGeneratedStubs.cpp" -o "$STUB/UnityGeneratedStubs.o" \
    || { log "generated-stub compile failed"; exit 1; }
xcrun --sdk iphoneos libtool -static -o "$STUB/libUnityGeneratedStubs.a" "$STUB/UnityGeneratedStubs.o" \
    || { log "generated-stub archive failed"; exit 1; }
log "   libUnityGeneratedStubs.a $(du -h "$STUB/libUnityGeneratedStubs.a" | cut -f1)  (RegisterAllClasses etc.)"

log ""
log "== 4. retarget GameAssembly.dylib for the bundle =="
# The dylib's install name still points at the Mac build tree
# (Library/Bee/artifacts/.../GameAssembly.dylib), which cannot resolve on a
# device. Rewrite it to @rpath so the framework's existing
# @executable_path/Frameworks rpath finds it inside the .app.
FWROOT="$OUT/frameworks"
mkdir -p "$FWROOT"
cp "$PAYLOAD/Frameworks/GameAssembly.dylib" "$FWROOT/GameAssembly.dylib"
ORIG_ID=$(otool -D "$FWROOT/GameAssembly.dylib" | tail -n +2)
log "   old install name: $ORIG_ID"
install_name_tool -id "@rpath/GameAssembly.dylib" "$FWROOT/GameAssembly.dylib" \
    || { log "install_name_tool failed"; exit 1; }
log "   new install name: $(otool -D "$FWROOT/GameAssembly.dylib" | tail -n +2)"

log ""
log "== 5. build =="
cd "$PAYLOAD"

DYLIB="$FWROOT/GameAssembly.dylib"
ENGINE="$PAYLOAD/Libraries/libiPhone-lib.a"
# Unity leaves $(OTHER_LDFLAGS_FRAMEWORK) undefined in the template and references
# it only from the UnityFramework target's OTHER_LDFLAGS. Passing the engine and
# dylib through that variable scopes them to the framework: OTHER_LDFLAGS itself
# applies to every target, which would force-load the 196 MB engine into the app
# binary as well - two engine copies in one process.
LDFLAGS="-ObjC -Wl,-force_load,$ENGINE $STUB/libUnityGeneratedStubs.a $DYLIB -Wl,-search_paths_first"

# Unity writes UNITY_VERSION_* into the pbxproj at build time; the Trampoline
# template ships with zero occurrences. UnityTrampolineConfigure.h:8 checks them
# with the C preprocessor, so they belong in GCC_PREPROCESSOR_DEFINITIONS -
# passing them as bare build settings defines nothing.
DEFINES="\$(inherited) UNITY_VERSION_VER=$UNITY_VER UNITY_VERSION_MAJ=$UNITY_MAJ UNITY_VERSION_MIN=$UNITY_MIN"

set -x
xcodebuild \
    -project Unity-iPhone.xcodeproj \
    -target Unity-iPhone \
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
    PRODUCT_NAME_APP="$APP_NAME" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    GCC_PREPROCESSOR_DEFINITIONS="$DEFINES" \
    OTHER_LDFLAGS_FRAMEWORK="$LDFLAGS" \
    2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set +x

log ""
if [ "$rc" -ne 0 ]; then
    log "================ BUILD FAILED (exit $rc) ================"
    grep -E 'error:' "$LOG" | head -40
    grep -iE 'undefined symbol|duplicate symbol|ld: ' "$LOG" | head -40
    exit "$rc"
fi
log "================ BUILD OK ================"

APP="$SYMROOT/Release-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || { log "app not found at $APP"; ls -la "$SYMROOT/Release-iphoneos"; exit 1; }

# dyld resolves @rpath/GameAssembly.dylib here
mkdir -p "$APP/Frameworks"
cp "$FWROOT/GameAssembly.dylib" "$APP/Frameworks/GameAssembly.dylib"
log "   embedded GameAssembly.dylib -> $APP/Frameworks/GameAssembly.dylib"

log ""
log "== 6. app bundle =="
log "   $APP"
log "   total $(du -sh "$APP" | cut -f1)"
log "   -- top level --"
ls -1 "$APP" | sed 's/^/     /' | tee -a "$LOG"
log "   -- frameworks --"
ls -1 "$APP/Frameworks" 2>/dev/null | sed 's/^/     /' | tee -a "$LOG"
log "   -- main binary --"
lipo -info "$APP/$APP_NAME" 2>/dev/null | sed 's/^/     /' | tee -a "$LOG"
log "   -- Data/ --"
log "     $(find "$APP/Data" -type f 2>/dev/null | wc -l | tr -d ' ') files, $(du -sh "$APP/Data" 2>/dev/null | cut -f1)"

log ""
log "== 7. package ipa =="
IPADIR="$OUT/ipa"
mkdir -p "$IPADIR/Payload"
cp -R "$APP" "$IPADIR/Payload/"
# strip any signature Xcode may have attached; the consumer signs it
find "$IPADIR/Payload" -name '_CodeSignature' -type d -exec rm -rf {} + 2>/dev/null || true
find "$IPADIR/Payload" -name 'CodeResources' -delete 2>/dev/null || true
( cd "$IPADIR" && zip -qry "$OUT/$APP_NAME-unsigned.ipa" Payload )
log "   $OUT/$APP_NAME-unsigned.ipa  $(du -h "$OUT/$APP_NAME-unsigned.ipa" | cut -f1)"

log ""
log "== 8. leftover undefined il2cpp refs (informational) =="
log "   main binary: $(nm -u "$APP/$APP_NAME" 2>/dev/null | grep -c il2cpp || echo 0)"
log "   framework  : $(nm -u "$APP/Frameworks/UnityFramework.framework/UnityFramework" 2>/dev/null | grep -c il2cpp || echo 0)"
log "   (these resolve at load time from GameAssembly.dylib)"

exit 0
