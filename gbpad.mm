// =============================================================================
// gbpad.mm - virtual gamepad injection for the SiNiSistar2 iOS port
//
// WHY THIS EXISTS
//   The game reads input through UnityEngine.InputSystem. Its action bindings
//   (read out of globalgamemanagers.assets) are:
//       Attack   <Gamepad>/buttonWest    <Keyboard>/x
//       Jump     <Gamepad>/buttonSouth   <Keyboard>/z
//       Magic01  <Gamepad>/buttonEast    <Keyboard>/v
//       Magic02  <Gamepad>/buttonNorth   <Keyboard>/c
//       Stick    <Gamepad>/leftStick, <Gamepad>/dpad, <Keyboard>/WASD
//
//   On iOS a Gamepad device is normally created by the Input System's iOS
//   backend, UnityEngine.InputSystem.iOS.LowLevel.GameController. That type is
//   compiled in only for mobile targets. This binary came from a macOS player
//   build, so the whole namespace is absent from global-metadata.dat:
//
//       UnityEngine.InputSystem.iOS   0 occurrences
//       GCController                  0 occurrences
//
//   The engine itself is fine - UnityFramework contains 118 iphone::NewInput
//   symbols including InitializeGameControllers(). But that path feeds Unity's
//   *legacy* input, and Input System never reads legacy joysticks. It also
//   reaches GameController through objc_getClass, which returns nil because the
//   framework is not linked.
//
//   So the bridge is built here: talk to the IL2CPP runtime directly, ask the
//   Input System to instantiate a Gamepad, and push state into it.
//
// TIMING - READ THIS BEFORE CHANGING ANYTHING
//   Getting the "runtime is usable" moment wrong has already cost two device
//   cycles, so the reasoning is recorded here.
//
//   1. v1 polled il2cpp_domain_get() from a constructor thread. The app died at
//      24 ms. Disassembly explains it: domain_get is not a plain accessor. When
//      its cached pointer is NULL it mallocs a 0x38-byte placeholder domain and
//      returns it, so it never returns NULL and tells you nothing. The crash was
//      in il2cpp_thread_attach on that placeholder.
//
//   2. v2 interposed il2cpp_init through __DATA,__interpose. On device the hook
//      never fired even though managed code was already running, so the
//      replacee slots are never bound. Dropped - a dormant hook whose failure
//      mode is "skip the real init" is a liability, not an asset.
//
//   3. v3 gated on a 10 s wall clock. Safe but wasteful: the game is playable at
//      4 s, so the gamepad was dead for the first 10 s of every launch.
//
//   Now: swizzle -[UnityAppController startUnity:] and set the flag after it
//   returns. Managed code provably runs inside startUnity (the v30 audio crash
//   was inside it), so the runtime is initialised by then. Lands at ~0.5 s.
//
//   Neither il2cpp_thread_attach nor il2cpp_domain_get_assemblies can be probed
//   before init - both dereference state that is not populated yet.
//
// NO HARDCODED STRUCT LAYOUT
//   Every offset below is resolved through il2cpp_field_get_offset at runtime.
//   InputEvent / StateEvent / InputStateBlock are internal Unity structures
//   whose field order differs between Input System versions; writing guessed
//   byte offsets would corrupt device state in ways that are hard to see.
//
// THREADING
//   State is queued from a background thread but InputSystem.Update() is left
//   to the player loop. Calling Update() by hand from another thread races the
//   front/back state-buffer swap, so the read-back waits for a real frame
//   instead.
//
// STAGE 1  prove the API is reachable, dump every field offset we depend on,
//          and create one Gamepad device.
// STAGE 2  build a StateEvent by hand, queue it, then read the value back
//          through the managed API. The read-back is the proof the chain works
//          and needs no physical controller.
//
// Everything prints to stderr, which the app already redirects into the boot
// log.
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TAG "[gbpad] "

// --- minimal IL2CPP type surface -------------------------------------------
// Opaque handles only. Every access goes through an exported il2cpp_* call so
// the layout stays the runtime's business.
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct MethodInfo MethodInfo;
typedef struct FieldInfo FieldInfo;
typedef struct Il2CppObject Il2CppObject;
typedef struct Il2CppString Il2CppString;
typedef struct Il2CppException Il2CppException;

static Il2CppDomain *(*f_domain_get)(void);
static const Il2CppAssembly **(*f_domain_get_assemblies)(const Il2CppDomain *, size_t *);
static Il2CppImage *(*f_assembly_get_image)(const Il2CppAssembly *);
static const char *(*f_image_get_name)(Il2CppImage *);
static Il2CppClass *(*f_class_from_name)(const Il2CppImage *, const char *, const char *);
static MethodInfo *(*f_class_get_method_from_name)(Il2CppClass *, const char *, int);
static const MethodInfo *(*f_class_get_methods)(Il2CppClass *, void **);
static const char *(*f_method_get_name)(const MethodInfo *);
static uint32_t (*f_method_get_param_count)(const MethodInfo *);
static Il2CppObject *(*f_runtime_invoke)(const MethodInfo *, void *, void **, Il2CppException **);
static Il2CppString *(*f_string_new)(const char *);
static const FieldInfo *(*f_class_get_fields)(Il2CppClass *, void **);
static size_t (*f_field_get_offset)(FieldInfo *);
static const char *(*f_field_get_name)(FieldInfo *);
static FieldInfo *(*f_class_get_field_from_name)(Il2CppClass *, const char *);
static void (*f_field_get_value)(Il2CppObject *, FieldInfo *, void *);
static int32_t (*f_class_value_size)(Il2CppClass *, uint32_t *);
static Il2CppClass *(*f_class_get_parent)(Il2CppClass *);
static const char *(*f_class_get_name)(Il2CppClass *);
static const char *(*f_class_get_namespace)(Il2CppClass *);
static Il2CppObject *(*f_thread_attach)(Il2CppDomain *);

// Set from the startUnity: hook once it has returned.
static volatile int g_il2cpp_ready = 0;

#define BIND(sym)                                                     \
    do {                                                              \
        *(void **)(&f_##sym) = dlsym(RTLD_DEFAULT, "il2cpp_" #sym);    \
        if (!f_##sym) {                                               \
            fprintf(stderr, TAG "missing symbol il2cpp_" #sym "\n");  \
            return 0;                                                 \
        }                                                             \
    } while (0)

static int bind_api(void)
{
    BIND(domain_get);
    BIND(domain_get_assemblies);
    BIND(assembly_get_image);
    BIND(image_get_name);
    BIND(class_from_name);
    BIND(class_get_method_from_name);
    BIND(class_get_methods);
    BIND(method_get_name);
    BIND(method_get_param_count);
    BIND(runtime_invoke);
    BIND(string_new);
    BIND(class_get_fields);
    BIND(field_get_offset);
    BIND(field_get_name);
    BIND(class_get_field_from_name);
    BIND(field_get_value);
    BIND(class_value_size);
    BIND(class_get_parent);
    BIND(class_get_name);
    BIND(class_get_namespace);
    BIND(thread_attach);
    return 1;
}
#undef BIND

// --- readiness: hook -[UnityAppController startUnity:] ----------------------
// Earlier attempts to detect "the runtime is usable" both failed on device:
//
//   1. Polling il2cpp_domain_get() crashed the app at 24 ms. Disassembly shows
//      why: it is NOT a plain accessor. If its cached pointer is NULL it
//      mallocs a 0x38-byte placeholder domain and returns that, so the return
//      value is never NULL and says nothing about readiness.
//      (GameAssembly vm 0x3f0aa4: ldr x0,[x20,#0x1f0]; cbz -> alloc; ret)
//
//   2. Interposing il2cpp_init never fired, even though managed code was
//      already running. The replacee slots are evidently never bound.
//
// il2cpp_thread_attach and il2cpp_domain_get_assemblies are both unsafe before
// init - the former dereferences a global that is not populated yet, the latter
// dereferences whatever the domain accessor returns. Neither can be probed.
//
// So we key off something we can actually observe. -[UnityAppController
// startUnity:] calls managed code before it returns (the v30 crash happened
// inside it, in AudioSettings/Mobile::InvokeOnMuteStateChanged), so by the time
// it returns il2cpp is definitely initialised. Swizzling an ObjC method is far
// more dependable than dyld symbol interposition, and it lands at ~0.5 s
// instead of a guessed wall-clock delay.

static IMP g_orig_startUnity = NULL;

static void gbpad_startUnity(id self, SEL _cmd)
{
    ((void (*)(id, SEL))g_orig_startUnity)(self, _cmd);
    fprintf(stderr, TAG "startUnity returned - runtime usable\n");
    g_il2cpp_ready = 1;
}

static void install_startunity_hook(void)
{
    Class c = objc_getClass("UnityAppController");
    if (!c) {
        fprintf(stderr, TAG "UnityAppController not registered yet\n");
        return;
    }
    Method m = class_getInstanceMethod(c, sel_registerName("startUnity:"));
    if (!m) {
        fprintf(stderr, TAG "startUnity: not found\n");
        return;
    }
    g_orig_startUnity = method_getImplementation(m);
    method_setImplementation(m, (IMP)gbpad_startUnity);
    fprintf(stderr, TAG "startUnity: hooked\n");
}

// Independent second path. If UnityAppController lives inside UnityFramework it
// may not be registered yet when this constructor runs, in which case the
// swizzle above quietly does nothing. The app only becomes active after Unity
// has launched, so this fires slightly later but never misses.
static void on_did_become_active(NSNotification *note)
{
    (void)note;
    if (!g_il2cpp_ready) {
        fprintf(stderr, TAG "applicationDidBecomeActive - runtime usable\n");
        g_il2cpp_ready = 1;
    }
}

// --- helpers ---------------------------------------------------------------

static Il2CppImage *find_image(Il2CppDomain *domain, const char *needle)
{
    size_t n = 0;
    const Il2CppAssembly **asms = f_domain_get_assemblies(domain, &n);
    if (!asms) {
        fprintf(stderr, TAG "domain_get_assemblies returned null\n");
        return NULL;
    }
    for (size_t i = 0; i < n; i++) {
        Il2CppImage *img = f_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *nm = f_image_get_name(img);
        if (nm && strstr(nm, needle)) {
            fprintf(stderr, TAG "assembly matched: %s\n", nm);
            return img;
        }
    }
    fprintf(stderr, TAG "no assembly matching '%s' among %zu\n", needle, n);
    return NULL;
}

static void dump_fields(Il2CppClass *klass, const char *label)
{
    if (!klass) {
        fprintf(stderr, TAG "dump %-22s <class null>\n", label);
        return;
    }
    uint32_t align = 0;
    fprintf(stderr, TAG "fields of %s::%s (value size %d)\n",
            f_class_get_namespace(klass), f_class_get_name(klass),
            f_class_value_size(klass, &align));
    void *iter = NULL;
    const FieldInfo *f;
    while ((f = f_class_get_fields(klass, &iter)) != NULL)
        fprintf(stderr, TAG "    %-30s @ %zu\n",
                f_field_get_name((FieldInfo *)f), f_field_get_offset((FieldInfo *)f));
}

static void dump_methods(Il2CppClass *klass, const char *label, const char *filter)
{
    if (!klass) {
        fprintf(stderr, TAG "methods %-22s <class null>\n", label);
        return;
    }
    fprintf(stderr, TAG "methods of %s::%s%s%s\n",
            f_class_get_namespace(klass), f_class_get_name(klass),
            filter ? " matching " : "", filter ? filter : "");
    void *iter = NULL;
    const MethodInfo *m;
    int shown = 0;
    while ((m = f_class_get_methods(klass, &iter)) != NULL) {
        const char *nm = f_method_get_name(m);
        if (!nm) continue;
        if (filter && !strstr(nm, filter)) continue;
        fprintf(stderr, TAG "    %s/%u\n", nm, f_method_get_param_count(m));
        if (++shown >= 40) { fprintf(stderr, TAG "    ...\n"); break; }
    }
}

static int field_off(Il2CppClass *klass, const char *name)
{
    FieldInfo *f = f_class_get_field_from_name(klass, name);
    return f ? (int)f_field_get_offset(f) : -1;
}

// Auto-properties and explicit-layout structs do not expose the field name you
// would guess from the public API, so try the plausible spellings in order.
static int field_off_any(Il2CppClass *klass, const char *const *names, int n)
{
    for (int i = 0; i < n; i++) {
        int o = field_off(klass, names[i]);
        if (o >= 0) {
            fprintf(stderr, TAG "  %s -> @%d\n", names[i], o);
            return o;
        }
    }
    return -1;
}

// il2cpp reports struct field offsets including a 16-byte object header.
static int inner(int reported) { return reported >= 16 ? reported - 16 : -1; }

// A bare "AddDevice threw" tells us nothing actionable, and guessing at the
// cause costs a 2.19 GB install cycle. Pull the real message out.
// An Il2CppString is a 16-byte header, an int32 length, then UTF-16 data, so
// this needs no extra exported symbol.
static void exc_message(Il2CppException *exc, char *out, size_t n)
{
    out[0] = 0;
    if (!exc) return;
    // The object header starts with the class pointer; no API needed.
    Il2CppClass *k = *(Il2CppClass **)exc;
    while (k && strcmp(f_class_get_name(k), "Exception") != 0)
        k = f_class_get_parent(k);
    if (!k) { snprintf(out, n, "<not an Exception>"); return; }
    MethodInfo *m = f_class_get_method_from_name(k, "get_Message", 0);
    if (!m) { snprintf(out, n, "<no get_Message>"); return; }
    Il2CppException *inner_exc = NULL;
    Il2CppObject *s = f_runtime_invoke(m, exc, NULL, &inner_exc);
    if (inner_exc || !s) { snprintf(out, n, "<get_Message failed>"); return; }
    int32_t len = *(int32_t *)((char *)s + 16);
    const uint16_t *ch = (const uint16_t *)((char *)s + 20);
    if (len < 0) len = 0;
    size_t j = 0;
    for (int32_t i = 0; i < len && j + 1 < n; i++)
        out[j++] = (ch[i] < 0x80) ? (char)ch[i] : '?';
    out[j] = 0;
}

// Search a class and its ancestors for a method. ReadValue lives on the
// generic base InputControl<TValue>, not on StickControl itself, so a plain
// lookup on the concrete class comes back empty.
//
// Kept as a fallback only. On device this walked the chain from StickControl
// and returned nothing - the chain crosses the generic InputControl<Vector2>
// instantiation, and il2cpp_class_get_parent does not traverse that reliably.
static MethodInfo *find_method_up(Il2CppClass *klass, const char *name, int argc, int maxDepth)
{
    Il2CppClass *k = klass;
    for (int i = 0; k && i < maxDepth; i++) {
        MethodInfo *m = f_class_get_method_from_name(k, name, argc);
        if (m) {
            fprintf(stderr, TAG "  %s/%d found on %s\n", name, argc, f_class_get_name(k));
            return m;
        }
        k = f_class_get_parent(k);
    }
    return NULL;
}

// --- stage 1 ---------------------------------------------------------------

static Il2CppObject *g_device = NULL;
static Il2CppClass *g_cGamepad = NULL;
static Il2CppClass *g_cSys = NULL;
static Il2CppClass *g_cStateBlock = NULL;
static Il2CppClass *g_cInputEvent = NULL;
static Il2CppClass *g_cStateEvent = NULL;
static Il2CppClass *g_cStick = NULL;
static Il2CppClass *g_cGamepadState = NULL;
static Il2CppClass *g_cInputControl = NULL;
static MethodInfo *g_readValueAsObject = NULL;

// Kept alive so the state can be re-queued. QueueEvent copies the event into
// its own buffer, so one allocation can be fed repeatedly.
static void *g_evBuffer = NULL;
static uint32_t g_evBufferSize = 0;
static MethodInfo *g_queueMethod = NULL;

// Pointers into g_evBuffer, so the ticker can rewrite just the fields it cares
// about instead of rebuilding the whole event.
static float *g_stickPtr = NULL;
static uint32_t *g_buttonsPtr = NULL;
static int g_buttonsOff = 0;

// The injected sequence walks through these phases. See gbpad_inject_tick.
static int g_phase = 0;
static int g_tick = 0;

static MethodInfo *g_addMethod = NULL;
static Il2CppString *g_sLayout = NULL;
static Il2CppString *g_sName = NULL;

static int stage2(void);
static void gbpad_readback(void);
static void gbpad_inject_tick(void);
static void gbpad_create_device(int attempt);

static int g_stateBlockOff = -1;   // InputDevice.m_StateBlock (absolute in object)
static int g_deviceIdOff = -1;     // InputDevice.m_DeviceId (absolute in object)
static int g_stateBlockSize = 0;

// Offsets below are relative to the START of the containing struct. il2cpp
// reports struct field offsets as if the struct carried the same 16-byte object
// header as a class, so the real offset is always (reported - 16). Confirmed
// against the reported sizes: InputStateBlock reports 16 for a 16-byte struct,
// GamepadState 28 for a 28-byte struct, InputDevice 376 with its last field at
// 384 -> 368+8 = 376.
static int g_fmtOff = -1;          // InputStateBlock.<format>k__BackingField
static int g_byteOffOff = -1;      // InputStateBlock.m_ByteOffset
static int g_sizeBitsOff = -1;     // InputStateBlock.<sizeInBits>k__BackingField
static int g_leftStickOff = 4;     // GamepadState.leftStick - NOT 0, `buttons` is first
static int g_gamepadStateSize = 0;

static int g_evTypeOff = 12;       // InputEvent.m_Type
static int g_evSizeOff = 16;       // InputEvent.m_SizeInBytes
static int g_evDeviceOff = 18;     // InputEvent.m_DeviceId
static int g_stFormatOff = 20;     // StateEvent.stateFormat
static int g_payloadOff = 24;      // StateEvent.stateData - where the state bytes go
static int g_evTypeFound = 0;

static int stage1(void)
{
    Il2CppDomain *domain = f_domain_get();
    if (!domain) {
        fprintf(stderr, TAG "domain still null\n");
        return 0;
    }
    f_thread_attach(domain);
    fprintf(stderr, TAG "domain up, thread attached\n");

    Il2CppImage *img = find_image(domain, "Unity.InputSystem");
    if (!img) return -1;

    g_cGamepad    = f_class_from_name(img, "UnityEngine.InputSystem", "Gamepad");
    Il2CppClass *cDevice = f_class_from_name(img, "UnityEngine.InputSystem", "InputDevice");
    g_cSys        = f_class_from_name(img, "UnityEngine.InputSystem", "InputSystem");
    g_cStateBlock = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "InputStateBlock");
    Il2CppClass *cGamepadState = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "GamepadState");
    g_cGamepadState = cGamepadState;
    g_cInputEvent = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "InputEvent");
    g_cStateEvent = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "StateEvent");
    g_cStick      = f_class_from_name(img, "UnityEngine.InputSystem.Controls", "StickControl");
    g_cInputControl = f_class_from_name(img, "UnityEngine.InputSystem", "InputControl");

    fprintf(stderr, TAG "class Gamepad         %s\n", g_cGamepad ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputDevice     %s\n", cDevice ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputSystem     %s\n", g_cSys ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputStateBlock %s\n", g_cStateBlock ? "ok" : "MISSING");
    fprintf(stderr, TAG "class GamepadState    %s\n", cGamepadState ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputEvent      %s\n", g_cInputEvent ? "ok" : "MISSING");
    fprintf(stderr, TAG "class StateEvent      %s\n", g_cStateEvent ? "ok" : "MISSING");
    fprintf(stderr, TAG "class StickControl    %s\n", g_cStick ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputControl    %s\n", g_cInputControl ? "ok" : "MISSING");

    // The layout dump is the contract for stage 2. Offsets are re-derived at
    // runtime, but printing them makes a mismatch obvious instead of silently
    // corrupting device state.
    dump_fields(g_cStateBlock, "InputStateBlock");
    dump_fields(cGamepadState, "GamepadState");
    dump_fields(g_cInputEvent, "InputEvent");
    dump_fields(g_cStateEvent, "StateEvent");
    dump_fields(cDevice, "InputDevice");
    dump_methods(g_cSys, "InputSystem", "AddDevice");
    dump_methods(g_cSys, "InputSystem", "QueueEvent");

    if (!g_cSys || !cDevice || !g_cStateBlock || !g_cInputEvent || !g_cStateEvent) {
        fprintf(stderr, TAG "required classes missing\n");
        return -1;
    }

    // ReadValueAsObject is declared on InputControl, the non-generic base.
    // Walking up from StickControl failed on device, so ask for the class by
    // name and read the method straight off it. The chain walk stays as a
    // fallback in case the class is renamed.
    if (g_cInputControl) {
        g_readValueAsObject = f_class_get_method_from_name(g_cInputControl, "ReadValueAsObject", 0);
        if (g_readValueAsObject)
            fprintf(stderr, TAG "ReadValueAsObject on InputControl\n");
    }
    if (!g_readValueAsObject && g_cStick)
        g_readValueAsObject = find_method_up(g_cStick, "ReadValueAsObject", 0, 12);
    if (!g_readValueAsObject)
        fprintf(stderr, TAG "WARN ReadValueAsObject unresolved, readback will be skipped\n");

    uint32_t align = 0;
    g_stateBlockOff = field_off(cDevice, "m_StateBlock");
    g_deviceIdOff   = field_off(cDevice, "m_DeviceId");

    // InputStateBlock exposes auto-properties, so the metadata fields are the
    // compiler-generated backing fields. There is no plain `format`/`sizeInBits`.
    static const char *const fmtNames[]  = {"<format>k__BackingField", "format", "m_Format"};
    static const char *const byteNames[] = {"m_ByteOffset", "byteOffset"};
    static const char *const bitsNames[] = {"<sizeInBits>k__BackingField", "sizeInBits", "m_SizeInBits"};
    g_fmtOff      = inner(field_off_any(g_cStateBlock, fmtNames, 3));
    g_byteOffOff  = inner(field_off_any(g_cStateBlock, byteNames, 2));
    g_sizeBitsOff = inner(field_off_any(g_cStateBlock, bitsNames, 3));
    g_stateBlockSize = f_class_value_size(g_cStateBlock, &align);
    if (g_stateBlockSize <= 0 || g_stateBlockSize > 64) g_stateBlockSize = 16;

    // GamepadState starts with `buttons` (4 bytes), so leftStick is at 4.
    static const char *const stickNames[] = {"leftStick"};
    int fStick = field_off_any(g_cGamepadState, stickNames, 1);
    g_leftStickOff = inner(fStick);
    if (g_leftStickOff < 0) g_leftStickOff = 4;

    // buttons is the first field of GamepadState; resolve it rather than assume.
    static const char *const btnNames[] = {"buttons"};
    g_buttonsOff = inner(field_off_any(g_cGamepadState, btnNames, 1));
    if (g_buttonsOff < 0) g_buttonsOff = 0;
    g_gamepadStateSize = f_class_value_size(g_cGamepadState, &align);
    if (g_gamepadStateSize <= 0 || g_gamepadStateSize > 128) g_gamepadStateSize = 28;

    // StateEvent exposes stateSizeInBytes/stateOffset as *properties*; only
    // baseEvent, stateFormat and stateData exist as fields.
    static const char *const typeNames[] = {"m_Type", "Type"};
    static const char *const sizeNames[] = {"m_SizeInBytes", "sizeInBytes"};
    static const char *const devNames[]  = {"m_DeviceId", "deviceId"};
    int fType = field_off_any(g_cInputEvent, typeNames, 2);
    int fSize = field_off_any(g_cInputEvent, sizeNames, 2);
    int fDev  = field_off_any(g_cInputEvent, devNames, 2);
    if (inner(fType) >= 0) { g_evTypeOff = inner(fType); g_evTypeFound = 1; }
    if (inner(fSize) >= 0) g_evSizeOff = inner(fSize);
    if (inner(fDev)  >= 0) g_evDeviceOff = inner(fDev);

    static const char *const sfNames[] = {"stateFormat"};
    static const char *const sdNames[] = {"stateData"};
    int fSf = field_off_any(g_cStateEvent, sfNames, 1);
    int fSd = field_off_any(g_cStateEvent, sdNames, 1);
    if (inner(fSf) >= 0) g_stFormatOff = inner(fSf);
    if (inner(fSd) >= 0) g_payloadOff  = inner(fSd);

    fprintf(stderr, TAG "resolved device: m_StateBlock@%d(size %d) m_DeviceId@%d\n",
            g_stateBlockOff, g_stateBlockSize, g_deviceIdOff);
    fprintf(stderr, TAG "resolved block : format@%d byteOffset@%d sizeInBits@%d\n",
            g_fmtOff, g_byteOffOff, g_sizeBitsOff);
    fprintf(stderr, TAG "resolved gamepad: leftStick@%d size=%d\n",
            g_leftStickOff, g_gamepadStateSize);
    fprintf(stderr, TAG "resolved event : m_Type@%d%s m_SizeInBytes@%d m_DeviceId@%d\n",
            g_evTypeOff, g_evTypeFound ? "" : " (DEFAULT)", g_evSizeOff, g_evDeviceOff);
    fprintf(stderr, TAG "resolved state : stateFormat@%d payload@%d\n",
            g_stFormatOff, g_payloadOff);

    if (g_stateBlockOff < 0 || g_deviceIdOff < 0 || g_fmtOff < 0 ||
        g_byteOffOff < 0 || g_sizeBitsOff < 0 ||
        g_stFormatOff < 0 || g_payloadOff < 0) {
        fprintf(stderr, TAG "cannot resolve required offsets\n");
        return -1;
    }

    // AddDevice(string layout, string name, InputDevice deviceToCopyFrom)
    MethodInfo *add = f_class_get_method_from_name(g_cSys, "AddDevice", 3);
    if (!add) add = f_class_get_method_from_name(g_cSys, "AddDevice", 1);
    if (!add) {
        fprintf(stderr, TAG "no usable AddDevice overload\n");
        return -1;
    }
    g_addMethod = add;
    g_sLayout = f_string_new("Gamepad");
    g_sName = f_string_new("GBPad");

    // InputSystem.AddDevice mutates the device list owned by a manager created
    // on the main thread. Calling it from here threw on device, so hand the
    // device work over rather than poking it cross-thread.
    fprintf(stderr, TAG "AddDevice/%u resolved, handing off to main thread\n",
            f_method_get_param_count(add));
    dispatch_async(dispatch_get_main_queue(), ^{ gbpad_create_device(0); });
    return 1;
}

// --- stage 2 ---------------------------------------------------------------

static int stage2(void)
{
    if (!g_device) return -1;

    // Copy the device's own state block out so nothing about its layout is
    // assumed. Field offsets inside it were resolved in stage 1.
    unsigned char sb[256];
    if (g_stateBlockSize > (int)sizeof(sb)) {
        fprintf(stderr, TAG "state block unexpectedly large (%d)\n", g_stateBlockSize);
        return -1;
    }
    memset(sb, 0, sizeof(sb));
    memcpy(sb, (unsigned char *)g_device + g_stateBlockOff, g_stateBlockSize);

    int devId = *(int *)((unsigned char *)g_device + g_deviceIdOff);
    uint32_t fmt = 0, byteOffset = 0, sizeInBits = 0;
    memcpy(&fmt, sb + g_fmtOff, 4);
    memcpy(&byteOffset, sb + g_byteOffOff, 4);
    memcpy(&sizeInBits, sb + g_sizeBitsOff, 4);

    fprintf(stderr, TAG "device: id=%d format=0x%08x byteOffset=%u sizeInBits=%u\n",
            devId, fmt, byteOffset, sizeInBits);

    // The event payload is the GamepadState struct. Its declared size is the
    // authority here - the state block's sizeInBits can be narrower than the
    // struct because the device only exposes part of it.
    uint32_t stateBytes = (uint32_t)g_gamepadStateSize;
    if (stateBytes == 0 || stateBytes > 128) {
        fprintf(stderr, TAG "implausible state size %u, skipping stage 2\n", stateBytes);
        return -1;
    }

    // Calibrate FourCC packing against a value we can verify: the Gamepad state
    // format is 'GPAD'. Whichever packing reproduces it tells us how to spell
    // 'STAT' for the event type, so no constant is taken on faith.
    const uint32_t GPAD_BE = 0x47504144;  // 'G'<<24 | 'P'<<16 | 'A'<<8 | 'D'
    const uint32_t GPAD_LE = 0x44415047;  // 'D'<<24 | 'A'<<16 | 'P'<<8 | 'G'
    uint32_t evType;
    if (fmt == GPAD_BE)      { evType = 0x53544154; fprintf(stderr, TAG "FourCC packing: big-endian\n"); }
    else if (fmt == GPAD_LE) { evType = 0x54415453; fprintf(stderr, TAG "FourCC packing: little-endian\n"); }
    else {
        evType = 0x53544154;
        fprintf(stderr, TAG "format 0x%08x not GPAD, assuming big-endian\n", fmt);
    }

    unsigned char *ev = (unsigned char *)calloc(1, g_payloadOff + stateBytes);
    if (!ev) return -1;

    uint32_t total = (uint32_t)(g_payloadOff + stateBytes);
    memcpy(ev + g_evTypeOff, &evType, 4);
    uint16_t sz16 = (uint16_t)total;
    memcpy(ev + g_evSizeOff, &sz16, 2);
    // m_DeviceId is a ushort in InputEvent; writing 4 bytes here would clobber
    // whatever follows it.
    uint16_t devId16 = (uint16_t)devId;
    memcpy(ev + g_evDeviceOff, &devId16, 2);
    memcpy(ev + g_stFormatOff, &fmt, 4);

    // Synthetic pattern: leftStick pushed to +X. leftStick sits at +4 inside
    // GamepadState because `buttons` occupies the first 4 bytes.
    float *state = (float *)(ev + g_payloadOff + g_leftStickOff);
    state[0] = 0.60f;
    state[1] = 0.00f;
    MethodInfo *queue = f_class_get_method_from_name(g_cSys, "QueueEvent", 1);
    if (!queue) {
        fprintf(stderr, TAG "InputSystem.QueueEvent/1 not found\n");
        free(ev);
        return -1;
    }
    g_queueMethod = queue;

    void *eventPtrValue = ev;
    void *args[1] = { &eventPtrValue };
    Il2CppException *exc = NULL;
    f_runtime_invoke(queue, NULL, args, &exc);
    if (exc) {
        char msg[256];
        exc_message(exc, msg, sizeof msg);
        fprintf(stderr, TAG "QueueEvent threw: %s\n", msg);
        free(ev);
        return -1;
    }
    fprintf(stderr, TAG "QUEUED type=0x%08x dev=%d total=%u stick@%d leftStick=(%.2f,%.2f)\n",
            evType, devId, total, g_payloadOff + g_leftStickOff, state[0], state[1]);

    // QueueEvent copies the event into its own buffer, so this allocation can
    // be fed again. Keep it: the state has to be re-asserted every frame or so,
    // because the Input System treats each update as a fresh state and the
    // stick would fall back to zero once the single event ages out.
    g_evBuffer = ev;
    g_evBufferSize = total;
    g_stickPtr = state;
    g_buttonsPtr = (uint32_t *)(ev + g_payloadOff + g_buttonsOff);
    *g_buttonsPtr = 0u;
    g_phase = 0;
    g_tick = 0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ gbpad_readback(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ gbpad_inject_tick(); });
    return 0;
}

// Walk a short scripted sequence so one install answers three questions at
// once: does an axis reach the game, do buttons reach the game, and does the
// menu respond. The game binds <Gamepad>/buttonSouth and <Keyboard>/x to jump
// and uses the same action for menu confirm.
//
// The state has to be re-asserted every tick: each InputSystem update treats
// the last queued state as current, so a single event would age out.
static void gbpad_inject_tick(void)
{
    if (!g_device || !g_evBuffer || !g_queueMethod) return;

    int stop = 0;

    if (g_phase == 0) {
        if (g_tick == 0)
            fprintf(stderr, TAG "phase 1: holding leftStick (0.60, 0.00)\n");
        g_tick++;
        if (g_tick > 8) {
            if (g_stickPtr) { g_stickPtr[0] = 0.0f; g_stickPtr[1] = 0.0f; }
            g_phase = 1;
            g_tick = 0;
            fprintf(stderr, TAG "phase 2: pulsing buttonSouth\n");
        }
    } else if (g_phase == 1) {
        g_tick++;
        int down = (g_tick % 2) == 1;
        if (g_buttonsPtr) *g_buttonsPtr = down ? 1u : 0u;   // GamepadButton.ButtonSouth
        fprintf(stderr, TAG "  buttonSouth %s\n", down ? "down" : "up");
        if (g_tick > 8) {
            if (g_buttonsPtr) *g_buttonsPtr = 0u;
            g_phase = 2;
            g_tick = 0;
            fprintf(stderr, TAG "phase 3: pulsing Start\n");
        }
    } else if (g_phase == 2) {
        g_tick++;
        int down = (g_tick % 2) == 1;
        if (g_buttonsPtr) *g_buttonsPtr = down ? 4096u : 0u;  // GamepadButton.Start
        fprintf(stderr, TAG "  Start %s\n", down ? "down" : "up");
        if (g_tick > 4) stop = 1;
    } else {
        stop = 1;
    }

    if (stop) {
        if (g_buttonsPtr) *g_buttonsPtr = 0u;
        g_phase = 3;
        fprintf(stderr, TAG "injection finished\n");
        return;
    }

    void *ptr = g_evBuffer;
    void *args[1] = { &ptr };
    Il2CppException *exc = NULL;
    f_runtime_invoke(g_queueMethod, NULL, args, &exc);
    if (exc) {
        char msg[256];
        exc_message(exc, msg, sizeof msg);
        fprintf(stderr, TAG "re-queue threw: %s\n", msg);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ gbpad_inject_tick(); });
}

// Read back through the managed API - the proof the chain works, with no
// controller involved and no gameplay side effects beyond the stick value.
static void gbpad_readback(void)
{
    MethodInfo *getCurrent = f_class_get_method_from_name(g_cGamepad, "get_current", 0);
    MethodInfo *getStick = f_class_get_method_from_name(g_cGamepad, "get_leftStick", 0);
    MethodInfo *readObj = g_readValueAsObject;

    if (!getCurrent || !getStick || !readObj) {
        fprintf(stderr, TAG "readback unavailable (get_current=%p get_leftStick=%p ReadValueAsObject=%p)\n",
                (void *)getCurrent, (void *)getStick, (void *)readObj);
        return;
    }

    Il2CppException *e1 = NULL;
    Il2CppObject *cur = f_runtime_invoke(getCurrent, NULL, NULL, &e1);
    if (!cur || e1) {
        fprintf(stderr, TAG "readback: Gamepad.current null\n");
        return;
    }
    Il2CppException *e2 = NULL;
    Il2CppObject *stick = f_runtime_invoke(getStick, cur, NULL, &e2);
    if (!stick || e2) {
        fprintf(stderr, TAG "readback: leftStick control null\n");
        return;
    }
    Il2CppException *e3 = NULL;
    Il2CppObject *boxed = f_runtime_invoke(readObj, stick, NULL, &e3);
    if (!boxed || e3) {
        char msg[256];
        exc_message(e3, msg, sizeof msg);
        fprintf(stderr, TAG "readback: ReadValueAsObject failed: %s\n", msg);
        return;
    }
    // Boxed Vector2: il2cpp object header (klass*, monitor) then the value.
    float *v = (float *)((unsigned char *)boxed + 2 * sizeof(void *));
    fprintf(stderr, TAG "READBACK leftStick = (%.3f, %.3f)%s\n", v[0], v[1],
            (v[0] > 0.5f) ? "   <== INJECTION WORKS" : "   <== did not take");
}

// --- device creation, on the main thread -----------------------------------
// InputSystem.AddDevice is not thread safe: it walks and mutates the device list
// owned by a manager created on the main thread. Called from the worker it threw
// on device, so everything that touches a device now runs on the main queue.
//
// Retries exist because the Input System manager is created by the player loop
// initialiser, which may not have run yet at the moment startUnity: returns.
static void gbpad_create_device(int attempt)
{
    if (g_device) return;
    if (attempt >= 20) {
        fprintf(stderr, TAG "AddDevice still failing after %d attempts, stopping\n", attempt);
        return;
    }

    Il2CppException *exc = NULL;
    Il2CppObject *dev = NULL;
    if (f_method_get_param_count(g_addMethod) >= 3) {
        void *args[3] = { g_sLayout, g_sName, NULL };
        dev = f_runtime_invoke(g_addMethod, NULL, args, &exc);
    } else {
        void *args[1] = { g_sLayout };
        dev = f_runtime_invoke(g_addMethod, NULL, args, &exc);
    }

    if (exc || !dev) {
        char msg[256];
        exc_message(exc, msg, sizeof msg);
        fprintf(stderr, TAG "AddDevice attempt %d failed: %s\n",
                attempt + 1, exc ? msg : "returned null");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ gbpad_create_device(attempt + 1); });
        return;
    }

    g_device = dev;
    fprintf(stderr, TAG "GAMEPAD CREATED at %p (attempt %d)\n", (void *)dev, attempt + 1);

    MethodInfo *getCurrent = f_class_get_method_from_name(g_cGamepad, "get_current", 0);
    if (getCurrent) {
        Il2CppException *e2 = NULL;
        Il2CppObject *cur = f_runtime_invoke(getCurrent, NULL, NULL, &e2);
        fprintf(stderr, TAG "Gamepad.current -> %p%s\n", (void *)cur,
                (cur == dev) ? "  (matches)" : "");
    }

    // Give the player loop a frame to register the device before feeding state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ stage2(); });
}

// --- bootstrap -------------------------------------------------------------

static void *worker(void *unused)
{
    (void)unused;

    // Wait for startUnity: to return. That is the earliest point at which the
    // runtime is provably usable, and it lands around 0.5 s - the game is
    // already playable at 4 s, so a wall-clock gate would be pure dead time.
    //
    // If the hook was never installed, we stop rather than probe blind: an
    // early call into il2cpp is what killed the app in the first version.
    int tenths = 0;
    const int LIMIT = 300;   // 30 s hard stop
    while (!g_il2cpp_ready && tenths < LIMIT) {
        usleep(100 * 1000);
        tenths++;
        if (tenths % 50 == 0)
            fprintf(stderr, TAG "still waiting for startUnity: %d s\n", tenths / 10);
    }
    if (!g_il2cpp_ready) {
        fprintf(stderr, TAG "startUnity never fired after %d s, not probing\n", LIMIT / 10);
        return NULL;
    }
    fprintf(stderr, TAG "proceeding at %d.%ds\n", tenths / 10, tenths % 10);

    usleep(300 * 1000);   // let Input System finish its own static init

    if (!bind_api()) {
        fprintf(stderr, TAG "IL2CPP API unreachable from UnityFramework\n");
        return NULL;
    }
    fprintf(stderr, TAG "IL2CPP API bound\n");

    int resolved = 0;
    for (int i = 0; i < 40 && !resolved; i++) {
        int r = stage1();
        if (r == 1) { resolved = 1; break; }
        if (r < 0) { fprintf(stderr, TAG "stage 1 failed, stopping\n"); return NULL; }
        usleep(250 * 1000);
    }
    if (!resolved) {
        fprintf(stderr, TAG "could not resolve InputSystem after retries\n");
        return NULL;
    }
    fprintf(stderr, TAG "stage 1 complete, device creation queued on main thread\n");
    return NULL;
}

__attribute__((constructor))
static void gbpad_init(void)
{
    fprintf(stderr, TAG "loaded\n");
    if (!dlsym(RTLD_DEFAULT, "il2cpp_domain_get")) {
        fprintf(stderr, TAG "il2cpp symbols not global, dlopen GameAssembly\n");
        dlopen("@rpath/GameAssembly.framework/GameAssembly", RTLD_NOW | RTLD_GLOBAL);
    }
    // Must run before UIApplicationMain, which is why it happens here: this
    // constructor fires while the app dlopens UnityFramework.
    install_startunity_hook();
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *n) { on_did_become_active(n); }];
    pthread_t t;
    if (pthread_create(&t, NULL, worker, NULL) == 0)
        pthread_detach(t);
    else
        fprintf(stderr, TAG "pthread_create failed\n");
}
