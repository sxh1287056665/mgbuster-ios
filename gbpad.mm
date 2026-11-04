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
#import <objc/message.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TAG "[gbpad] "

// The scripted six-phase injection test drives the same virtual device as the
// on-screen controls, so leaving it on would fight the player's fingers. Set to
// 1 only when diagnosing whether the device can be written at all.
#define GBPAD_SELFTEST 0

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
// Used only for diagnostics: InputEvent hides its header inside a native
// struct, so printing that struct's real name and fields is the only way to
// stop guessing at the layout.
static void *(*f_field_get_type)(FieldInfo *);
static char *(*f_type_get_name)(const void *);
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
BIND(field_get_type);
BIND(type_get_name);
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

// Look a type up in every loaded assembly. InputSystem's event header is
// declared in UnityEngineInternal.Input, which lives in a different assembly
// from InputSystem itself, so a lookup restricted to the InputSystem image
// silently returns null and the caller falls back to guessed offsets.
static Il2CppClass *find_class_any(Il2CppDomain *domain, const char *ns, const char *name)
{
    size_t n = 0;
    const Il2CppAssembly **asms = f_domain_get_assemblies(domain, &n);
    if (!asms) return NULL;
    for (size_t i = 0; i < n; i++) {
        Il2CppImage *im = f_assembly_get_image(asms[i]);
        if (!im) continue;
        Il2CppClass *k = f_class_from_name(im, ns, name);
        if (k) {
            const char *in = f_image_get_name(im);
            fprintf(stderr, TAG "found %s.%s in %s\n", ns, name, in ? in : "?");
            return k;
        }
    }
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
static Il2CppClass *g_cDpad = NULL;
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

static MethodInfo *g_evalMagnitude = NULL;
static MethodInfo *g_sysUpdate = NULL;
static int g_updateStepOff = -1;
static uint32_t g_stepFirst = 0;
static int g_stepCaptured = 0;
static int g_stepChecked = 0;
static int g_manualUpdate = 0;

// Keyboard injection. The main menu of a PC game is far more likely to listen to
// Enter or Space than to a gamepad button, so both get tried in one run.
static Il2CppClass *g_cKeyboard = NULL;
static Il2CppClass *g_cKeyControl = NULL;
static Il2CppObject *g_kbDevice = NULL;
static void *g_kbBuffer = NULL;
static uint32_t g_kbTotal = 0;
static uint32_t g_kbFormat = 0;
static uint32_t g_kbDevId = 0;
static int g_kbByteOff = -1;    // per-key byte offset inside the keyboard state
static int g_kbBitOff = -1;     // per-key bit within that byte
static int g_bitOffOff = -1;    // offset of InputStateBlock.bitOffset
static uint32_t g_kbDevByteOff = 0;  // keyboard device root, absolute in the global buffer
static uint32_t g_devByteOff = 0;    // gamepad device root, absolute in the global buffer
static MethodInfo *g_curStatePtr = NULL;

// InputEvent.m_EventId sits at the end of the 20-byte native header, after the
// 8-byte time field. Zero means "no id"; the Input System treats ids as
// required, so hand out unique ones.
static int g_evIdOff = 16;
static int g_evTimeOff = 8;          // InputEvent.time, a double
static int g_evId = 1;
// Where InputDevice keeps the timestamp it judges events against. Borrowing it
// keeps queued events neither stale nor from the future.
static int g_devTimeOff = 280;
static void *g_clockDevice = NULL;

// Direct state writes. The queued-event path never reaches device state on
// device: QueueEvent is accepted without throwing, but the front buffer keeps
// reading (0,0) no matter how often InputSystem.Update is pumped. currentStatePtr
// points straight into the live buffer, so writing there skips the whole event
// pipeline.
static MethodInfo *g_getLeftStick = NULL;
static MethodInfo *g_getButtonSouth = NULL;
static MethodInfo *g_getStartButton = NULL;

static MethodInfo *g_addMethod = NULL;
static Il2CppString *g_sLayout = NULL;
static Il2CppString *g_sName = NULL;

static int stage2(void);
static void gbpad_readback(void);
static void gbpad_inject_tick(void);
static void gbpad_create_device(int attempt);
static void gbpad_make_keyboard(void);
static float gbpad_mag(void);

// On-screen control plumbing, defined further down. The base pointer has to
// live up here because stage2 fills it in, and C++ has no tentative
// definitions - declaring it twice would be a redefinition.
static void *g_gbStateBase = NULL;
static void gbpad_resolve_buttons(void);
static void gbpad_install_overlay(int attempt);

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

static int g_evTypeOff = 0;        // InputEvent.type      - FourCC, must be non-zero
static int g_evSizeOff = 4;        // InputEvent.sizeInBytes
static int g_evDeviceOff = 8;      // InputEvent.deviceId
static int g_evSizeWidth = 4;      // 4 for uint, 2 for ushort
static int g_evDevWidth = 4;
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
    g_cDpad       = f_class_from_name(img, "UnityEngine.InputSystem.Controls", "DpadControl");
    g_cInputControl = f_class_from_name(img, "UnityEngine.InputSystem", "InputControl");
    g_cKeyboard   = f_class_from_name(img, "UnityEngine.InputSystem", "Keyboard");
    g_cKeyControl = f_class_from_name(img, "UnityEngine.InputSystem.Controls", "KeyControl");

    fprintf(stderr, TAG "class Gamepad         %s\n", g_cGamepad ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputDevice     %s\n", cDevice ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputSystem     %s\n", g_cSys ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputStateBlock %s\n", g_cStateBlock ? "ok" : "MISSING");
    fprintf(stderr, TAG "class GamepadState    %s\n", cGamepadState ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputEvent      %s\n", g_cInputEvent ? "ok" : "MISSING");
    fprintf(stderr, TAG "class StateEvent      %s\n", g_cStateEvent ? "ok" : "MISSING");
    fprintf(stderr, TAG "class StickControl    %s\n", g_cStick ? "ok" : "MISSING");
    fprintf(stderr, TAG "class DpadControl     %s\n", g_cDpad ? "ok" : "MISSING");
    if (g_cDpad) dump_methods(g_cDpad, "DpadControl", "get_");
    fprintf(stderr, TAG "class InputControl    %s\n", g_cInputControl ? "ok" : "MISSING");
    fprintf(stderr, TAG "class Keyboard        %s\n", g_cKeyboard ? "ok" : "MISSING");
    fprintf(stderr, TAG "class KeyControl      %s\n", g_cKeyControl ? "ok" : "MISSING");

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

    // Readback chain. ReadValueAsObject is declared on InputControl, but asking
    // for it by name returns NULL even though metadata shows 12 method
    // definitions using that name, so it is not dependable here.
    // EvaluateMagnitude is the primary path instead: same class, no arguments,
    // and it returns a plain float, so there is no boxed-layout guesswork.
    if (g_cInputControl) {
        g_evalMagnitude = f_class_get_method_from_name(g_cInputControl, "EvaluateMagnitude", 0);
        g_readValueAsObject = f_class_get_method_from_name(g_cInputControl, "ReadValueAsObject", 0);
    }
    if (!g_evalMagnitude && g_cStick)
        g_evalMagnitude = find_method_up(g_cStick, "EvaluateMagnitude", 0, 12);
    if (g_cInputControl)
        g_curStatePtr = f_class_get_method_from_name(g_cInputControl, "get_currentStatePtr", 0);
    if (g_cGamepad) {
        g_getLeftStick   = f_class_get_method_from_name(g_cGamepad, "get_leftStick", 0);
        g_getButtonSouth = f_class_get_method_from_name(g_cGamepad, "get_buttonSouth", 0);
        g_getStartButton = f_class_get_method_from_name(g_cGamepad, "get_startButton", 0);
    }
    fprintf(stderr, TAG "readback: EvaluateMagnitude=%s ReadValueAsObject=%s currentStatePtr=%s\n",
            g_evalMagnitude ? "ok" : "MISSING", g_readValueAsObject ? "ok" : "MISSING",
            g_curStatePtr ? "ok" : "MISSING");
    fprintf(stderr, TAG "controls: leftStick=%s buttonSouth=%s start=%s\n",
            g_getLeftStick ? "ok" : "MISSING", g_getButtonSouth ? "ok" : "MISSING",
            g_getStartButton ? "ok" : "MISSING");

    // Whether the queue is ever drained is a separate question from whether an
    // event was accepted. InputSystem.Update drives the drain and is hooked in
    // through the PlayerLoop, which can silently fail under IL2CPP. This step
    // counter is the cheapest way to find out.
    g_sysUpdate = f_class_get_method_from_name(g_cSys, "Update", 0);
    fprintf(stderr, TAG "InputSystem.Update = %p\n", (void *)g_sysUpdate);

    uint32_t align = 0;
    g_stateBlockOff = field_off(cDevice, "m_StateBlock");
    g_deviceIdOff   = field_off(cDevice, "m_DeviceId");
    g_updateStepOff = field_off(cDevice, "m_CurrentUpdateStepCount");
    fprintf(stderr, TAG "m_CurrentUpdateStepCount @%d\n", g_updateStepOff);

    // InputStateBlock exposes auto-properties, so the metadata fields are the
    // compiler-generated backing fields. There is no plain `format`/`sizeInBits`.
    static const char *const fmtNames[]  = {"<format>k__BackingField", "format", "m_Format"};
    static const char *const byteNames[] = {"m_ByteOffset", "byteOffset"};
    static const char *const bitsNames[] = {"<sizeInBits>k__BackingField", "sizeInBits", "m_SizeInBits"};
    g_fmtOff      = inner(field_off_any(g_cStateBlock, fmtNames, 3));
    g_byteOffOff  = inner(field_off_any(g_cStateBlock, byteNames, 2));
    g_sizeBitsOff = inner(field_off_any(g_cStateBlock, bitsNames, 3));
    static const char *const bitNames[] = {"<bitOffset>k__BackingField", "bitOffset", "m_BitOffset"};
    g_bitOffOff = inner(field_off_any(g_cStateBlock, bitNames, 3));
    fprintf(stderr, TAG "InputStateBlock bitOffset @%d\n", g_bitOffOff);
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

    // InputEvent's header lives in UnityEngineInternal.Input.NativeInputEvent,
    // which is Unity's own native event struct and sits in a different assembly
    // from InputSystem. Looking it up in the InputSystem image always missed,
    // which is why the offsets fell back to guesses.
    Il2CppClass *cNative = find_class_any(domain, "UnityEngineInternal.Input",
                                          "NativeInputEvent");
    if (!cNative)
        cNative = find_class_any(domain, "UnityEngine.InputSystem.LowLevel",
                                 "NativeInputEvent");
    fprintf(stderr, TAG "NativeInputEvent lookup: %s\n", cNative ? "found" : "MISSING");
    if (f_class_get_field_from_name && f_field_get_type && f_type_get_name) {
        FieldInfo *fe = f_class_get_field_from_name(g_cInputEvent, "m_Event");
        if (fe) {
            char *tn = f_type_get_name(f_field_get_type(fe));
            fprintf(stderr, TAG "InputEvent.m_Event type = %s\n", tn ? tn : "(null)");
        }
    }
    static const char *const nType[] = {"type", "m_Type"};
    static const char *const nSize[] = {"sizeInBytes", "m_SizeInBytes"};
    static const char *const nDev[]  = {"deviceId", "m_DeviceId"};
    static const char *const nId[]   = {"eventId", "m_EventId"};
    static const char *const nTime[] = {"time", "m_Time"};
    int nT = -1, nS = -1, nD = -1, nI = -1, nTi = -1;
    if (cNative) {
        nT  = inner(field_off_any(cNative, nType, 2));
        nS  = inner(field_off_any(cNative, nSize, 2));
        nD  = inner(field_off_any(cNative, nDev, 2));
        nI  = inner(field_off_any(cNative, nId, 2));
        nTi = inner(field_off_any(cNative, nTime, 2));
        dump_fields(cNative, "NativeInputEvent");
    }
    if (nT >= 0 && nS >= 0 && nD >= 0) {
        g_evTypeOff   = nT;
        g_evSizeOff   = nS;
        g_evDeviceOff = nD;
        g_evTypeFound = 1;
        // Field widths come from the gap to the next field, so a ushort
        // sizeInBytes/deviceId pair is not overwritten by a 4-byte store.
        int nextS = (nD > nS) ? nD : (nI >= 0 ? nI : (nTi >= 0 ? nTi : 20));
        int nextD = (nI >= 0 && nI > nD) ? nI : (nTi >= 0 && nTi > nD ? nTi : 20);
        g_evSizeWidth = nextS - nS;
        g_evDevWidth  = nextD - nD;
    } else {
        // Confirmed layout of UnityEngineInternal.Input.NativeInputEvent, read
        // off the real type name in the device log:
        //   type @0 (4)  sizeInBytes @4 (ushort)  deviceId @6 (ushort)
        //   time @8 (double)  eventId @16 (int)   -> 20 bytes
        // The 20-byte size is what makes stateFormat land at 20 and stateData
        // at 24, which the metadata already confirmed independently.
        g_evTypeOff   = 0;
        g_evSizeOff   = 4;
        g_evSizeWidth = 2;
        g_evDeviceOff = 6;
        g_evDevWidth  = 2;
        g_evIdOff     = 16;
    }

    // eventId must never land on deviceId. This used to sit inside the block
    // above, so when the native lookup failed the id stayed at 8 - the same
    // offset as deviceId - and bumping it each frame rewrote the device the
    // event was addressed to. Decide it unconditionally.
    if (nI >= 0)
        g_evIdOff = nI;
    else if (g_evDeviceOff == 6)
        g_evIdOff = 16;             // type@0 size@4u16 dev@6u16 time@8 id@16
    else
        g_evIdOff = g_evDeviceOff + 4;  // type@0 size@4 dev@8 id@12 time@16

    static const char *const sfNames[] = {"stateFormat"};
    static const char *const sdNames[] = {"stateData"};
    int fSf = field_off_any(g_cStateEvent, sfNames, 1);
    int fSd = field_off_any(g_cStateEvent, sdNames, 1);
    if (inner(fSf) >= 0) g_stFormatOff = inner(fSf);
    if (inner(fSd) >= 0) g_payloadOff  = inner(fSd);
    if (nTi >= 0) g_evTimeOff = nTi;

    // Timestamp source. QueueEvent does not fill in the time, and a calloc'd
    // buffer leaves it 0 - which InputSystem reads as "before this app started"
    // and discards. The device's own m_LastUpdateTimeInternal is exactly the
    // clock InputSystem judges events against, so borrow it instead of guessing
    // at a time base.
    static const char *const luNames[] = {"m_LastUpdateTimeInternal", "lastUpdateTimeInternal"};
    int lu = inner(field_off_any(cDevice, luNames, 2));
    if (lu >= 0) g_devTimeOff = lu;
    fprintf(stderr, TAG "clock: device.m_LastUpdateTimeInternal @%d\n", g_devTimeOff);

    fprintf(stderr, TAG "resolved device: m_StateBlock@%d(size %d) m_DeviceId@%d\n",
            g_stateBlockOff, g_stateBlockSize, g_deviceIdOff);
    fprintf(stderr, TAG "resolved block : format@%d byteOffset@%d sizeInBits@%d\n",
            g_fmtOff, g_byteOffOff, g_sizeBitsOff);
    fprintf(stderr, TAG "resolved gamepad: leftStick@%d size=%d\n",
            g_leftStickOff, g_gamepadStateSize);
    fprintf(stderr, TAG "resolved event : type@%d%s size@%d(w%d) dev@%d(w%d) id@%d time@%d\n",
            g_evTypeOff, g_evTypeFound ? "" : " (DEFAULT!)", g_evSizeOff, g_evSizeWidth,
            g_evDeviceOff, g_evDevWidth, g_evIdOff, nTi);
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
    // A control's InputStateBlock.m_ByteOffset is absolute inside the global
    // state buffers, not relative to the device. The keyboard path already
    // subtracts the device root for exactly this reason; the gamepad needs the
    // same treatment or every button lands at byte 672.
    g_devByteOff = byteOffset;
    g_clockDevice = g_device;

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
    // Widths come from the resolved NativeInputEvent layout: writing 4 bytes
    // into a 2-byte field would land on top of the field behind it.
    if (g_evSizeWidth >= 4) {
        memcpy(ev + g_evSizeOff, &total, 4);
    } else {
        uint16_t sz16 = (uint16_t)total;
        memcpy(ev + g_evSizeOff, &sz16, 2);
    }
    if (g_evDevWidth >= 4) {
        int32_t d32 = (int32_t)devId;
        memcpy(ev + g_evDeviceOff, &d32, 4);
    } else {
        uint16_t d16 = (uint16_t)devId;
        memcpy(ev + g_evDeviceOff, &d16, 2);
    }
    memcpy(ev + g_stFormatOff, &fmt, 4);

    // Read the header back: the previous build logged the intended values while
    // writing them to the wrong place, so the log looked healthy and the event
    // was dead on arrival.
    uint32_t rbType = 0, rbSize = 0, rbDev = 0, rbFmt = 0;
    memcpy(&rbType, ev + g_evTypeOff, 4);
    memcpy(&rbSize, ev + g_evSizeOff, g_evSizeWidth >= 4 ? 4 : 2);
    memcpy(&rbDev,  ev + g_evDeviceOff, g_evDevWidth >= 4 ? 4 : 2);
    memcpy(&rbFmt,  ev + g_stFormatOff, 4);
    fprintf(stderr, TAG "event hdr: type=0x%08x size=%u dev=%u fmt=0x%08x "
                        "(at %d/%d/%d/%d)\n",
            rbType, rbSize, rbDev, rbFmt,
            g_evTypeOff, g_evSizeOff, g_evDeviceOff, g_stFormatOff);

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

    // Bring up real input: derive each button's bit from its own control
    // metadata, then put the controls on screen. The scripted self-test is
    // opt-in because it drives the same device.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        gbpad_resolve_buttons();
        gbpad_install_overlay(0);
    });

#if GBPAD_SELFTEST
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ gbpad_inject_tick(); });
#endif
    return 0;
}

// --- measurement -----------------------------------------------------------

static void gbpad_bump_id(void *buf)
{
    if (!buf) return;
    int id = g_evId++;
    if (g_evId <= 0) g_evId = 1;
    memcpy((unsigned char *)buf + g_evIdOff, &id, 4);
}

// Stamp the event with the clock InputSystem is currently using. A zero
// timestamp makes the event look older than the session and it gets dropped
// before it ever reaches the device state.
static void gbpad_stamp_time(void *buf)
{
    if (!buf || !g_clockDevice || g_devTimeOff < 0) return;
    double t = 0.0;
    memcpy(&t, (unsigned char *)g_clockDevice + g_devTimeOff, 8);
    if (t <= 0.0) return;
    memcpy((unsigned char *)buf + g_evTimeOff, &t, 8);
}

// The player loop does not call InputSystem.Update, so drive it at roughly a
// frame rate. 5 Hz (the injection tick rate) is far too coarse: per-frame
// semantics like WasPressedThisFrame and any per-frame polling would miss a
// 200 ms press entirely.
static void gbpad_pump(void)
{
    if (!g_manualUpdate || !g_sysUpdate) return;
    Il2CppException *e = NULL;
    f_runtime_invoke(g_sysUpdate, NULL, NULL, &e);
    if (e) {
        char msg[256];
        exc_message(e, msg, sizeof msg);
        fprintf(stderr, TAG "pump Update threw: %s\n", msg);
        g_manualUpdate = 0;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ gbpad_pump(); });
}

// EvaluateMagnitude returns a plain float, so this needs no layout guesswork.
// -1 means "could not read", which is different from a real 0.
static float gbpad_mag(void)
{
    if (!g_evalMagnitude || !g_cGamepad) return -1.0f;
    MethodInfo *getCurrent = f_class_get_method_from_name(g_cGamepad, "get_current", 0);
    MethodInfo *getStick = f_class_get_method_from_name(g_cGamepad, "get_leftStick", 0);
    if (!getCurrent || !getStick) return -1.0f;

    Il2CppException *e = NULL;
    Il2CppObject *cur = f_runtime_invoke(getCurrent, NULL, NULL, &e);
    if (!cur || e) return -1.0f;
    e = NULL;
    Il2CppObject *stick = f_runtime_invoke(getStick, cur, NULL, &e);
    if (!stick || e) return -1.0f;

    // Direct read of the control's live state, bypassing every managed wrapper.
    // currentStatePtr already points at the control's own slot, so the Vector2
    // is the first 8 bytes. This is the measurement that cannot be fooled by a
    // magnitude function behaving unexpectedly.
    if (g_curStatePtr) {
        Il2CppException *e4 = NULL;
        void *sp = (void *)f_runtime_invoke(g_curStatePtr, stick, NULL, &e4);
        if (sp && !e4 && (uintptr_t)sp > 0x100000000ULL) {
            float a = 0, b = 0;
            memcpy(&a, sp, 4);
            memcpy(&b, (unsigned char *)sp + 4, 4);
            fprintf(stderr, TAG "  raw stick @%p = (%.3f, %.3f)\n", sp, a, b);
        } else {
            fprintf(stderr, TAG "  raw stick ptr = %p (exc=%p)\n", sp, (void *)e4);
        }
    }

    e = NULL;
    Il2CppObject *boxed = f_runtime_invoke(g_evalMagnitude, stick, NULL, &e);
    if (!boxed || e) return -1.0f;
    return *(float *)((unsigned char *)boxed + 2 * sizeof(void *));
}

// --- direct state writes ---------------------------------------------------
// The queued-event path is a dead end on device: QueueEvent is accepted without
// throwing, but the front buffer keeps reading (0,0) however often Update is
// pumped. currentStatePtr points straight into that live buffer, so writing
// there bypasses the queue, the manager and the update loop entirely.

static void *ctrl_state(Il2CppObject *dev, MethodInfo *getter)
{
    if (!dev || !getter || !g_curStatePtr) return NULL;
    Il2CppException *e = NULL;
    Il2CppObject *c = f_runtime_invoke(getter, dev, NULL, &e);
    if (!c || e) return NULL;
    e = NULL;
    void *sp = (void *)f_runtime_invoke(g_curStatePtr, c, NULL, &e);
    if (!sp || e) return NULL;
    if ((uintptr_t)sp < 0x100000000ULL) return NULL;
    return sp;
}

static void gbpad_direct_apply(void)
{
    if (!g_device || !g_curStatePtr) return;

    float sx = g_stickPtr ? g_stickPtr[0] : 0.0f;
    float sy = g_stickPtr ? g_stickPtr[1] : 0.0f;
    void *sp = ctrl_state(g_device, g_getLeftStick);
    if (sp) {
        memcpy(sp, &sx, 4);
        memcpy((unsigned char *)sp + 4, &sy, 4);
    }

    // ButtonControl stores a float, so pressed is 1.0 rather than a bit.
    uint32_t b = g_buttonsPtr ? *g_buttonsPtr : 0u;
    float south = (b & 1u)    ? 1.0f : 0.0f;   // GamepadButton.ButtonSouth
    float start = (b & 4096u) ? 1.0f : 0.0f;   // GamepadButton.Start
    void *bs = ctrl_state(g_device, g_getButtonSouth);
    if (bs) memcpy(bs, &south, 4);
    void *st = ctrl_state(g_device, g_getStartButton);
    if (st) memcpy(st, &start, 4);
}

// --- keyboard injection ----------------------------------------------------
// The main menu of a PC game is more likely to answer to Enter than to a
// gamepad face button, and the game's metadata carries both input APIs. A
// Keyboard device is built exactly like the gamepad was, and the per-key bit
// position is read off the real KeyControl instead of hardcoding Key enum
// values.

static void gbpad_make_keyboard(void)
{
    if (g_kbDevice || !g_cKeyboard || !g_addMethod) {
        fprintf(stderr, TAG "keyboard: skipped (device=%p class=%p add=%p)\n",
                (void *)g_kbDevice, (void *)g_cKeyboard, (void *)g_addMethod);
        return;
    }

    Il2CppString *layout = f_string_new("Keyboard");
    Il2CppString *name   = f_string_new("GBPadKB");
    void *args[3] = { layout, name, NULL };
    Il2CppException *exc = NULL;
    Il2CppObject *dev = f_runtime_invoke(g_addMethod, NULL, args, &exc);
    if (!dev || exc) {
        char msg[256];
        exc_message(exc, msg, sizeof msg);
        fprintf(stderr, TAG "keyboard AddDevice failed: %s\n", exc ? msg : "returned null");
        return;
    }
    g_kbDevice = dev;
    fprintf(stderr, TAG "KEYBOARD CREATED at %p\n", (void *)dev);

    unsigned char *d = (unsigned char *)dev;
    uint32_t fmt = 0, bits = 0, devByteOff = 0;
    memcpy(&fmt,  d + g_stateBlockOff + g_fmtOff, 4);
    memcpy(&bits, d + g_stateBlockOff + g_sizeBitsOff, 4);
    memcpy(&devByteOff, d + g_stateBlockOff + g_byteOffOff, 4);
    g_kbFormat = fmt;
    g_kbDevByteOff = devByteOff;

    uint32_t stateBytes = bits / 8;
    if (stateBytes == 0 || stateBytes > 64) stateBytes = 14;   // KeyboardState default

    uint16_t id16 = 0;
    memcpy(&id16, d + g_deviceIdOff, 2);
    g_kbDevId = id16;

    uint32_t total = (uint32_t)g_payloadOff + stateBytes;
    g_kbTotal = total;
    g_kbBuffer = calloc(1, total);
    if (!g_kbBuffer) { fprintf(stderr, TAG "keyboard: alloc failed\n"); return; }

    // Same packing rule the gamepad resolved to: FourCC reads as big-endian.
    uint32_t evType = (fmt == 0x44415047u) ? 0x54415453u : 0x53544154u;
    uint16_t sz16 = (uint16_t)total;
    memcpy((unsigned char *)g_kbBuffer + g_evTypeOff, &evType, 4);
    memcpy((unsigned char *)g_kbBuffer + g_evSizeOff, &sz16, 2);
    memcpy((unsigned char *)g_kbBuffer + g_evDeviceOff, &id16, 2);
    memcpy((unsigned char *)g_kbBuffer + g_stFormatOff, &fmt, 4);

    fprintf(stderr, TAG "keyboard: id=%u format=0x%08x byteOffset=%u state=%u bytes total=%u\n",
            g_kbDevId, g_kbFormat, g_kbDevByteOff, stateBytes, total);

    MethodInfo *cur = f_class_get_method_from_name(g_cKeyboard, "get_current", 0);
    if (cur) {
        Il2CppException *e2 = NULL;
        Il2CppObject *c = f_runtime_invoke(cur, NULL, NULL, &e2);
        fprintf(stderr, TAG "Keyboard.current -> %p%s\n", (void *)c,
                (c == dev) ? "  (matches)" : "");
    }
}

// Flip one key's bit in the keyboard state buffer. The bit position comes from
// the live KeyControl's state block, so no Key enum table is assumed.
static int gbpad_kb_set(const char *getterName, int down)
{
    if (!g_kbDevice || !g_kbBuffer || !g_cKeyboard) return 0;
    MethodInfo *getter = f_class_get_method_from_name(g_cKeyboard, getterName, 0);
    if (!getter) { fprintf(stderr, TAG "keyboard: %s not found\n", getterName); return 0; }

    Il2CppException *e = NULL;
    Il2CppObject *kc = f_runtime_invoke(getter, g_kbDevice, NULL, &e);
    if (!kc || e) { fprintf(stderr, TAG "keyboard: %s returned null\n", getterName); return 0; }

    unsigned char *c = (unsigned char *)kc;
    uint32_t byteOff = 0, bitOff = 0;
    memcpy(&byteOff, c + g_stateBlockOff + g_byteOffOff, 4);
    memcpy(&bitOff,  c + g_stateBlockOff + g_bitOffOff, 4);

    // byteOffset comes back as an ABSOLUTE position in the global state buffer,
    // not relative to the device root: on device every key reported 700, which
    // is exactly the keyboard device's own offset. Subtract the root, then fold
    // the bit index in - Key values above 7 straddle bytes (X reports bit 38,
    // i.e. byte 4 bit 6).
    uint32_t stateBytes = g_kbTotal - (uint32_t)g_payloadOff;
    if (byteOff < g_kbDevByteOff) {
        fprintf(stderr, TAG "keyboard: %s byte=%u below root %u\n",
                getterName, byteOff, g_kbDevByteOff);
        return 0;
    }
    uint32_t relBytes = byteOff - g_kbDevByteOff;
    uint32_t absBit = relBytes * 8u + bitOff;
    uint32_t bi = absBit / 8u;
    uint32_t shift = absBit % 8u;
    if (bi >= stateBytes) {
        fprintf(stderr, TAG "keyboard: %s out of range (rel=%u bit=%u -> byte %u of %u)\n",
                getterName, relBytes, bitOff, bi, stateBytes);
        return 0;
    }
    unsigned char *st = (unsigned char *)g_kbBuffer + g_payloadOff + bi;
    if (down) *st |=  (unsigned char)(1u << shift);
    else      *st &= (unsigned char)~(1u << shift);
    return 1;
}

static void gbpad_kb_queue(void)
{
    if (!g_kbDevice || !g_kbBuffer || !g_queueMethod) return;
    gbpad_bump_id(g_kbBuffer);
    void *ptr = g_kbBuffer;
    void *args[1] = { &ptr };
    Il2CppException *exc = NULL;
    f_runtime_invoke(g_queueMethod, NULL, args, &exc);
    if (exc) {
        char msg[256];
        exc_message(exc, msg, sizeof msg);
        fprintf(stderr, TAG "keyboard re-queue threw: %s\n", msg);
    }
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
        if (g_tick > 4) {
            if (g_buttonsPtr) *g_buttonsPtr = 0u;
            g_phase = 3;
            g_tick = 0;
            fprintf(stderr, TAG "phase 4: keyboard Enter\n");
        }
    } else if (g_phase == 3) {
        g_tick++;
        int down = (g_tick % 2) == 1;
        gbpad_kb_set("get_enterKey", down);
        fprintf(stderr, TAG "  Enter %s\n", down ? "down" : "up");
        if (g_tick > 8) {
            gbpad_kb_set("get_enterKey", 0);
            g_phase = 4;
            g_tick = 0;
            fprintf(stderr, TAG "phase 5: keyboard Space\n");
        }
    } else if (g_phase == 4) {
        g_tick++;
        int down = (g_tick % 2) == 1;
        gbpad_kb_set("get_spaceKey", down);
        fprintf(stderr, TAG "  Space %s\n", down ? "down" : "up");
        if (g_tick > 6) {
            gbpad_kb_set("get_spaceKey", 0);
            g_phase = 5;
            g_tick = 0;
            fprintf(stderr, TAG "phase 6: keyboard X\n");
        }
    } else if (g_phase == 5) {
        g_tick++;
        int down = (g_tick % 2) == 1;
        gbpad_kb_set("get_xKey", down);
        fprintf(stderr, TAG "  X %s\n", down ? "down" : "up");
        if (g_tick > 6) {
            gbpad_kb_set("get_xKey", 0);
            stop = 1;
        }
    } else {
        stop = 1;
    }

    // Write the same values straight into the live state buffer. This is the
    // path that actually has a chance of reaching the game.
    gbpad_direct_apply();

    if (stop) {
        if (g_buttonsPtr) *g_buttonsPtr = 0u;
        if (g_stickPtr) { g_stickPtr[0] = 0.0f; g_stickPtr[1] = 0.0f; }
        gbpad_direct_apply();
        g_phase = 6;
        fprintf(stderr, TAG "injection finished\n");
        return;
    }

    // Before queueing, settle the question of whether the queue is drained at
    // all. Read the per-device update step counter once, then again a few ticks
    // later. If it never moves, InputSystem.Update is not running and no amount
    // of queueing will reach the game.
    if (g_updateStepOff >= 0 && g_device) {
        uint32_t step = *(uint32_t *)((unsigned char *)g_device + g_updateStepOff);
        if (!g_stepCaptured) {
            g_stepCaptured = 1;
            g_stepFirst = step;
            fprintf(stderr, TAG "update step count starts at %u\n", step);
        } else if (!g_stepChecked && g_tick >= 3) {
            g_stepChecked = 1;
            if (step == g_stepFirst) {
                g_manualUpdate = 1;
                fprintf(stderr, TAG "update step stuck at %u - InputSystem.Update "
                        "is NOT running, pumping it at 60Hz\n", step);
                dispatch_async(dispatch_get_main_queue(), ^{ gbpad_pump(); });
            } else {
                fprintf(stderr, TAG "update step advanced %u -> %u, loop is alive\n",
                        g_stepFirst, step);
            }
        }
    }

    // If the player loop is not driving InputSystem, drive it here. This runs on
    // the main thread, so there is no contention with a player-loop update - it
    // simply is not happening. Draining before queueing keeps the front buffer
    // in step with the back buffer.
    if (g_manualUpdate && g_sysUpdate) {
        Il2CppException *ue = NULL;
        f_runtime_invoke(g_sysUpdate, NULL, NULL, &ue);
        if (ue) {
            char msg[256];
            exc_message(ue, msg, sizeof msg);
            fprintf(stderr, TAG "manual InputSystem.Update threw: %s\n", msg);
            g_manualUpdate = 0;
        }
    }

    gbpad_stamp_time(g_evBuffer);

    gbpad_bump_id(g_evBuffer);
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
    gbpad_kb_queue();

    // Drain again so the state we just queued actually lands in the device
    // buffer before the next frame reads it.
    if (g_manualUpdate && g_sysUpdate) {
        Il2CppException *ue2 = NULL;
        f_runtime_invoke(g_sysUpdate, NULL, NULL, &ue2);
    }

    // The whole point of this build: read the stick back AFTER a manual update
    // has run. If the magnitude finally moves, pumping works and the queue was
    // simply never drained. If it stays at zero, the events are being rejected
    // or Update() is not the thing that drains them.
    if (g_manualUpdate && (g_tick % 3) == 0) {
        uint32_t step = (g_updateStepOff >= 0)
            ? *(uint32_t *)((unsigned char *)g_device + g_updateStepOff) : 0;
        float m = gbpad_mag();
        fprintf(stderr, TAG "  [after manual update] step=%u mag=%.3f\n", step, m);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ gbpad_inject_tick(); });
}

// Read back through the managed API - the proof the chain works, with no
// controller involved and no gameplay side effects beyond the stick value.
static void gbpad_readback(void)
{
    float mag = gbpad_mag();
    if (mag < 0.0f) {
        fprintf(stderr, TAG "readback unavailable (EvaluateMagnitude=%p)\n",
                (void *)g_evalMagnitude);
        return;
    }
    fprintf(stderr, TAG "READBACK leftStick magnitude = %.3f%s\n", mag,
            (mag > 0.3f) ? "   <== INJECTION WORKS" : "   <== did not take");
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
    gbpad_make_keyboard();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ stage2(); });
}

// =============================================================================
// ON-SCREEN CONTROLS
//
// An xinput-shaped overlay: left stick, A/B/X/Y diamond, LB/RB, Start/Back.
// Values go into the injected Gamepad's live state buffer AND into the queued
// StateEvent, so the game sees a real gamepad either way.
//
// Button bits are NEVER hardcoded. Each ButtonControl carries its own
// InputStateBlock, whose m_ByteOffset (relative to the device state base) and
// bitOffset give the exact bit inside GamepadState.buttons. Guessing the
// GamepadButton enum order would press the wrong action, and a wrong bit is
// invisible in the log - so it is derived, then logged once for confirmation.
// =============================================================================

enum {
    GB_SOUTH,   // Jump      <Gamepad>/buttonSouth
    GB_EAST,    // Magic01   <Gamepad>/buttonEast
    GB_WEST,    // Attack    <Gamepad>/buttonWest
    GB_NORTH,   // Magic02   <Gamepad>/buttonNorth
    GB_START,
    GB_SELECT,
    GB_LB,
    GB_RB,
    GB_DUP,
    GB_DDOWN,
    GB_DLEFT,
    GB_DRIGHT,
    GB_LT,
    GB_RT,
    GB_LSTICK,
    GB_RSTICK,
    GB_NBTN
};

static const char *const kGBGetter[GB_NBTN] = {
    "get_buttonSouth", "get_buttonEast", "get_buttonWest", "get_buttonNorth",
    "get_startButton", "get_selectButton", "get_leftShoulder", "get_rightShoulder",
    "get_up", "get_down", "get_left", "get_right",
    "get_leftTrigger", "get_rightTrigger", "get_leftStickButton", "get_rightStickButton"
};

// Dpad children hang off the dpad control rather than off Gamepad, so the
// parent getter has to be resolved first. Everything else is one level deep.
static const char *const kGBParent[GB_NBTN] = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    "get_dpad", "get_dpad", "get_dpad", "get_dpad",
    NULL, NULL, NULL, NULL
};

// Triggers are analog float controls, not bits: writing a bit into their state
// would put 1.0f into the low byte and leave the rest of the float as garbage.
static const unsigned char kGBFloat[GB_NBTN] = {
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0
};

static const char *const kGBGlyph[GB_NBTN] = {
    "A", "B", "X", "Y", "START", "BACK", "LB", "RB",
    "\xE2\x96\xB2", "\xE2\x96\xBC", "\xE2\x97\x80", "\xE2\x96\xB6", "LT", "RT", "LS", "RS"
};

static MethodInfo *g_gbGetter[GB_NBTN];
// Where each button lives inside the device state buffer.
//
// `currentStatePtr` turned out to return the same pointer for every control on
// this binary - it is the device's state base, not a per-control slot. Pointer
// subtraction therefore yields a constant 4 for all eight buttons and puts every
// bit at index 36..45, which is why the first device run logged "bit 38 out of
// range" for all of them. The only trustworthy source for a control's position
// is its own InputStateBlock, whose m_ByteOffset is already absolute in that
// buffer, so the offsets are read from there and nowhere else.
static int g_gbByte[GB_NBTN];           // absolute byte inside the state buffer
static int g_gbBit[GB_NBTN];            // bit index within that byte
static int g_gbBitKnown[GB_NBTN];
static int g_gbStickByte = -1;          // absolute byte of leftStick

// g_gbStateBase is declared near the top, because stage2 fills it in.

// Touch and physical pad are tracked separately so lifting a finger never
// cancels a button the pad is still holding.
static unsigned g_gbHeldTouch = 0;
static unsigned g_gbHeldPad = 0;
static float g_gbStickTouch[2] = {0.0f, 0.0f};
static float g_gbStickPad[2] = {0.0f, 0.0f};
static volatile int g_gbPadStick = 0;
static volatile int g_gbLive = 0;       // set once the overlay is on screen

// Resolve one button's position from its own control metadata.
static void gbpad_resolve_button(int i)
{
    if (g_gbBitKnown[i] || !g_device || !g_gbStateBase) return;
    if (g_stateBlockOff < 0 || g_byteOffOff < 0 || g_bitOffOff < 0) return;

    // Dpad children hang off the dpad control, not off Gamepad. Walk to the
    // parent object first so the child getter has something to invoke on.
    Il2CppObject *owner = g_device;
    if (kGBParent[i]) {
        if (!g_cDpad) {
            fprintf(stderr, TAG "button %s: DpadControl class missing\n", kGBGetter[i]);
            return;
        }
        MethodInfo *pg = f_class_get_method_from_name(g_cGamepad, kGBParent[i], 0);
        if (!pg) {
            fprintf(stderr, TAG "button %s: parent getter %s not found\n",
                    kGBGetter[i], kGBParent[i]);
            return;
        }
        Il2CppException *pe = NULL;
        owner = f_runtime_invoke(pg, g_device, NULL, &pe);
        if (!owner || pe) {
            fprintf(stderr, TAG "button %s: parent %s returned null\n",
                    kGBGetter[i], kGBParent[i]);
            return;
        }
    }

    if (!g_gbGetter[i])
        g_gbGetter[i] = f_class_get_method_from_name(
            kGBParent[i] ? g_cDpad : g_cGamepad, kGBGetter[i], 0);
    if (!g_gbGetter[i]) {
        fprintf(stderr, TAG "button %s: getter not found\n", kGBGetter[i]);
        return;
    }

    Il2CppException *e = NULL;
    Il2CppObject *c = f_runtime_invoke(g_gbGetter[i], owner, NULL, &e);
    if (!c || e) return;

    uint32_t byteOff = 0, bitOff = 0;
    memcpy(&byteOff, (unsigned char *)c + g_stateBlockOff + g_byteOffOff, 4);
    memcpy(&bitOff,  (unsigned char *)c + g_stateBlockOff + g_bitOffOff, 4);

    if (bitOff > 31) {
        fprintf(stderr, TAG "button %s: implausible bit offset %u\n",
                kGBGetter[i], bitOff);
        return;
    }

    // m_ByteOffset is absolute in the global state buffers. The device root is
    // what currentStatePtr hands back, so subtract it to get the offset inside
    // the device's own state. Without this every button reported byte 672.
    if (byteOff < g_devByteOff) {
        fprintf(stderr, TAG "button %s: byte %u is below device root %u\n",
                kGBGetter[i], byteOff, g_devByteOff);
        return;
    }
    uint32_t rel = byteOff - g_devByteOff;
    if (rel > 64) {
        fprintf(stderr, TAG "button %s: implausible relative offset %u\n",
                kGBGetter[i], rel);
        return;
    }

    if (kGBFloat[i]) {
        // Analog control: a float lives at the byte offset, no bit index.
        g_gbByte[i] = (int)rel;
        g_gbBit[i] = -1;
    } else {
        // bitOff is counted from the start of the buttons field, so a bit past
        // the first byte belongs to the next one.
        g_gbByte[i] = (int)(rel + bitOff / 8);
        g_gbBit[i]  = (int)(bitOff % 8);
    }
    g_gbBitKnown[i] = 1;
    fprintf(stderr, TAG "control %-18s state[%d] %s (abs=%u root=%u rel=%u bit=%u)\n",
            kGBGetter[i], g_gbByte[i], kGBFloat[i] ? "float" : "bit",
            byteOff, g_devByteOff, rel, bitOff);
}

static void gbpad_resolve_buttons(void)
{
    // The base has to come from the LIVE device buffer, not from the queued
    // event payload - those are two different allocations. Every control
    // reports this same address, so it is the device base and needs no
    // adjustment.
    if (!g_gbStateBase && g_device && g_curStatePtr && g_getLeftStick) {
        void *sp = ctrl_state(g_device, g_getLeftStick);
        if (sp && (uintptr_t)sp > 0x100000000ULL)
            g_gbStateBase = sp;
    }
    if (!g_gbStateBase) {
        fprintf(stderr, TAG "live state base unavailable, buttons disabled\n");
        return;
    }

    if (g_gbStickByte < 0 && g_stateBlockOff >= 0 && g_byteOffOff >= 0) {
        Il2CppException *e = NULL;
        Il2CppObject *c = f_runtime_invoke(g_getLeftStick, g_device, NULL, &e);
        if (c && !e) {
            uint32_t bo = 0;
            memcpy(&bo, (unsigned char *)c + g_stateBlockOff + g_byteOffOff, 4);
            if (bo >= g_devByteOff && (bo - g_devByteOff) <= 64)
                g_gbStickByte = (int)(bo - g_devByteOff);
        }
    }
    if (g_gbStickByte < 0) g_gbStickByte = 4;

    fprintf(stderr, TAG "live state base = %p  stick@%d\n",
            g_gbStateBase, g_gbStickByte);
    for (int i = 0; i < GB_NBTN; i++) gbpad_resolve_button(i);
}

// One frame of input: live buffer first, then the queued event so the next
// InputSystem.Update re-asserts the same values instead of zeroing them.
static void gbpad_frame(void)
{
    if (!g_device || !g_curStatePtr || !g_gbStateBase || !g_gbLive) return;

    unsigned held = g_gbHeldTouch | g_gbHeldPad;
    float x = g_gbPadStick ? g_gbStickPad[0] : g_gbStickTouch[0];
    float y = g_gbPadStick ? g_gbStickPad[1] : g_gbStickTouch[1];

    unsigned char *live = (unsigned char *)g_gbStateBase;
    unsigned char *evp = (g_evBuffer && g_payloadOff >= 0)
                       ? (unsigned char *)g_evBuffer + g_payloadOff : NULL;

    // Touch only the state we own. Clearing whole words would stomp controls
    // the device may be reporting on its own.
    for (int i = 0; i < GB_NBTN; i++) {
        if (!g_gbBitKnown[i]) continue;
        int on = (held & (1u << i)) ? 1 : 0;
        if (g_gbBit[i] < 0) {
            // Analog trigger: a full float, not a bit. Bitwise writes would
            // leave 1.0f's upper bytes as whatever was already there.
            float f = on ? 1.0f : 0.0f;
            memcpy(live + g_gbByte[i], &f, 4);
            if (evp) memcpy(evp + g_gbByte[i], &f, 4);
            continue;
        }
        unsigned char mask = (unsigned char)(1u << g_gbBit[i]);
        unsigned char *p = live + g_gbByte[i];
        if (on) *p |= mask; else *p &= (unsigned char)~mask;
        if (evp) {
            unsigned char *q = evp + g_gbByte[i];
            if (on) *q |= mask; else *q &= (unsigned char)~mask;
        }
    }

    memcpy(live + g_gbStickByte, &x, 4);
    memcpy(live + g_gbStickByte + 4, &y, 4);
    if (evp) {
        memcpy(evp + g_gbStickByte, &x, 4);
        memcpy(evp + g_gbStickByte + 4, &y, 4);
    }

    if (g_evBuffer && g_queueMethod) {
        gbpad_stamp_time(g_evBuffer);
        gbpad_bump_id(g_evBuffer);
        void *ptr = g_evBuffer;
        void *args[1] = { &ptr };
        Il2CppException *e = NULL;
        f_runtime_invoke(g_queueMethod, NULL, args, &e);
    }

    if (g_manualUpdate && g_sysUpdate) {
        Il2CppException *ue = NULL;
        f_runtime_invoke(g_sysUpdate, NULL, NULL, &ue);
    }
}

@interface GBPadOverlay : UIView
- (void)startDriving;
@end

static NSString *const kGBLayoutKey = @"gbpad.layout.v1";

@implementation GBPadOverlay {
    UIView *_stickBase;
    UIView *_stickKnob;
    UIView *_btn[GB_NBTN];
    NSMutableDictionary<NSNumber *, NSNumber *> *_assign;
    UITouch *_stickTouch;
    CGPoint _stickCenter;
    CGFloat _stickRadius;
    CADisplayLink *_link;
    BOOL _laid;

    // Layout is stored normalised (0..1 of the overlay) so it survives a
    // rotation or a different device without any rescaling pass.
    CGPoint _pos[GB_NBTN];
    CGPoint _stickPos;
    CGFloat _stickScale;

    BOOL _edit;
    UITouch *_dragTouch;
    int _dragIdx;              // -2 = stick, -1 = none, else button index
    CGPoint _dragOffset;
    UILabel *_hint;
    UIButton *_reset;
}



// Defaults were taken off the working hard-coded layout and only normalised,
// so the first launch looks exactly like the version that already played.
- (void)defaultLayout
{
    static const float dflt[GB_NBTN][2] = {
        [GB_SOUTH]  = {0.881f, 0.861f},
        [GB_EAST]   = {0.936f, 0.741f},
        [GB_WEST]   = {0.825f, 0.741f},
        [GB_NORTH]  = {0.881f, 0.620f},
        [GB_START]  = {0.931f, 0.100f},
        [GB_SELECT] = {0.849f, 0.100f},
        [GB_LB]     = {0.835f, 0.509f},
        [GB_RB]     = {0.926f, 0.509f},
        [GB_DUP]    = {0.440f, 0.680f},
        [GB_DDOWN]  = {0.440f, 0.880f},
        [GB_DLEFT]  = {0.350f, 0.780f},
        [GB_DRIGHT] = {0.530f, 0.780f},
        [GB_LT]     = {0.835f, 0.420f},
        [GB_RT]     = {0.926f, 0.420f},
        [GB_LSTICK] = {0.115f, 0.935f},
        [GB_RSTICK] = {0.881f, 0.955f},
    };
    for (int i = 0; i < GB_NBTN; i++)
        _pos[i] = CGPointMake(dflt[i][0], dflt[i][1]);
    _stickPos = CGPointMake(0.115f, 0.750f);
    _stickScale = 1.0f;
}

- (void)loadLayout
{
    [self defaultLayout];
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:kGBLayoutKey];
    if (a.count != GB_NBTN * 2 + 1) return;
    for (int i = 0; i < GB_NBTN; i++)
        _pos[i] = CGPointMake([a[i * 2] floatValue], [a[i * 2 + 1] floatValue]);
    _stickPos = CGPointMake([a[GB_NBTN * 2] floatValue], [a[GB_NBTN * 2 + 1] floatValue]);
}

- (void)saveLayout
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:GB_NBTN * 2 + 1];
    for (int i = 0; i < GB_NBTN; i++) {
        [a addObject:@(_pos[i].x)];
        [a addObject:@(_pos[i].y)];
    }
    [a addObject:@(_stickPos.x)];
    [a addObject:@(_stickPos.y)];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kGBLayoutKey];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    _assign = [NSMutableDictionary dictionary];
    _dragIdx = -1;
    [self loadLayout];

    _stickBase = [[UIView alloc] initWithFrame:CGRectZero];
    _stickBase.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    _stickBase.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    _stickBase.layer.borderWidth = 2.0;
    _stickBase.userInteractionEnabled = NO;
    [self addSubview:_stickBase];

    _stickKnob = [[UIView alloc] initWithFrame:CGRectZero];
    _stickKnob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.24];
    _stickKnob.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
    _stickKnob.layer.borderWidth = 2.0;
    _stickKnob.userInteractionEnabled = NO;
    [self addSubview:_stickKnob];

    for (int i = 0; i < GB_NBTN; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectZero];
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.26];
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        b.layer.borderWidth = 2.0;
        b.userInteractionEnabled = NO;

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
        l.text = [NSString stringWithUTF8String:kGBGlyph[i]];
        l.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
        CGFloat fs = 11.0;
        if (i <= GB_NORTH) fs = 21.0;
        else if (i == GB_DUP || i == GB_DDOWN || i == GB_DLEFT || i == GB_DRIGHT) fs = 15.0;
        else if (i == GB_START || i == GB_SELECT || i == GB_LB || i == GB_RB) fs = 12.0;
        l.font = [UIFont boldSystemFontOfSize:fs];
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor clearColor];
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.6;
        l.tag = 99;
        [b addSubview:l];

        [self addSubview:b];
        _btn[i] = b;
    }

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.55;
    lp.cancelsTouchesInView = NO;
    [self addGestureRecognizer:lp];

    _hint = [[UILabel alloc] initWithFrame:CGRectZero];
    _hint.text = @"拖动控件调整位置";
    _hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _hint.font = [UIFont boldSystemFontOfSize:13.0];
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _hint.layer.cornerRadius = 8.0;
    _hint.clipsToBounds = YES;
    _hint.hidden = YES;
    _hint.userInteractionEnabled = NO;
    [self addSubview:_hint];

    _reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [_reset setTitle:@"重置" forState:UIControlStateNormal];
    [_reset setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _reset.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _reset.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _reset.layer.cornerRadius = 8.0;
    _reset.hidden = YES;
    [_reset addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_reset];

    return self;
}

- (void)sizeFor:(int)i
{
    CGFloat s = 70.0;
    if (i == GB_DUP || i == GB_DDOWN || i == GB_DLEFT || i == GB_DRIGHT) s = 56.0;
    else if (i == GB_LT || i == GB_RT || i == GB_LSTICK || i == GB_RSTICK) s = 56.0;
    else if (i == GB_START || i == GB_SELECT || i == GB_LB || i == GB_RB) s = 0.0;
    _btn[i].bounds = CGRectMake(0, 0, s > 0.0 ? s : 66.0, s > 0.0 ? s : 30.0);
    _btn[i].layer.cornerRadius = s > 0.0 ? s * 0.5 : 9.0;
    UIView *l = [_btn[i] viewWithTag:99];
    l.frame = _btn[i].bounds;
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    UIEdgeInsets si = self.safeAreaInsets;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat sd = 168.0;

    for (int i = 0; i < GB_NBTN; i++) {
        [self sizeFor:i];
        _btn[i].center = CGPointMake(si.left + _pos[i].x * (w - si.left - si.right),
                                     si.top + _pos[i].y * (h - si.top - si.bottom));
    }

    _stickBase.bounds = CGRectMake(0, 0, sd, sd);
    _stickBase.layer.cornerRadius = sd * 0.5;
    _stickBase.center = CGPointMake(si.left + _stickPos.x * (w - si.left - si.right),
                                    si.top + _stickPos.y * (h - si.top - si.bottom));
    _stickCenter = _stickBase.center;
    _stickRadius = sd * 0.5;

    CGFloat kd = 70.0;
    _stickKnob.bounds = CGRectMake(0, 0, kd, kd);
    _stickKnob.layer.cornerRadius = kd * 0.5;
    [self placeKnob:CGPointZero];

    _hint.frame = CGRectMake(w * 0.5 - 80, si.top + 6, 160, 28);
    _reset.frame = CGRectMake(w * 0.5 + 86, si.top + 6, 56, 28);

    _laid = YES;
}

- (void)placeKnob:(CGPoint)v
{
    _stickKnob.center = CGPointMake(_stickCenter.x + v.x * _stickRadius,
                                    _stickCenter.y + v.y * _stickRadius);
}

- (BOOL)stickHit:(CGPoint)p
{
    CGFloat dx = p.x - _stickCenter.x, dy = p.y - _stickCenter.y;
    CGFloat r = _stickRadius * 1.4;
    return (dx * dx + dy * dy) <= r * r;
}

- (int)buttonAt:(CGPoint)p
{
    for (int i = 0; i < GB_NBTN; i++) {
        if (CGRectContainsPoint(CGRectInset(_btn[i].frame, -10.0, -10.0), p))
            return i;
    }
    return -1;
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    _edit = !_edit;
    _hint.hidden = !_edit;
    _reset.hidden = !_edit;
    for (int i = 0; i < GB_NBTN; i++)
        _btn[i].layer.borderColor = (_edit
            ? [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:0.95]
            : [UIColor colorWithWhite:1.0 alpha:0.28]).CGColor;
    // Lifting every finger when entering edit mode avoids a half-held button
    // sticking once the same touch starts moving a control instead.
    [_assign removeAllObjects];
    g_gbHeldTouch = 0;
    if (_edit) [self saveLayout];
}

- (void)onReset
{
    [self defaultLayout];
    [self saveLayout];
    [self setNeedsLayout];
}

- (void)updateStick:(CGPoint)p
{
    CGFloat dx = p.x - _stickCenter.x, dy = p.y - _stickCenter.y;
    CGFloat len = sqrt(dx * dx + dy * dy);
    CGFloat maxr = _stickRadius;
    if (len > maxr && len > 0.0) { dx *= maxr / len; dy *= maxr / len; }

    CGFloat nx = dx / maxr;
    CGFloat ny = dy / maxr;      // screen Y grows downward
    CGFloat m = sqrt(nx * nx + ny * ny);

    const CGFloat dead = 0.14;
    float ox = 0.0f, oy = 0.0f;
    if (m > dead) {
        CGFloat s = (m - dead) / (1.0 - dead) / m;
        ox = (float)(nx * s);
        oy = (float)(-ny * s);   // InputSystem Y is up-positive
    }
    g_gbStickTouch[0] = ox;
    g_gbStickTouch[1] = oy;
    [self placeKnob:CGPointMake(dx / maxr, dy / maxr)];
}

- (void)refreshButtons
{
    unsigned m = 0;
    for (NSNumber *k in _assign) m |= (1u << [_assign[k] intValue]);
    g_gbHeldTouch = m;
    for (int i = 0; i < GB_NBTN; i++) {
        BOOL on = (m & (1u << i)) != 0;
        _btn[i].backgroundColor = on ? [UIColor colorWithWhite:1.0 alpha:0.40]
                                     : [UIColor colorWithWhite:0.0 alpha:0.26];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIEdgeInsets si = self.safeAreaInsets;
    CGFloat uw = w - si.left - si.right, uh = h - si.top - si.bottom;

    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];

        if (_edit) {
            if (_dragTouch) continue;
            if ([self stickHit:p]) {
                _dragTouch = t;
                _dragIdx = -2;
                _dragOffset = CGPointMake(_stickPos.x * uw + si.left - p.x,
                                          _stickPos.y * uh + si.top - p.y);
                continue;
            }
            int b = [self buttonAt:p];
            if (b >= 0) {
                _dragTouch = t;
                _dragIdx = b;
                _dragOffset = CGPointMake(si.left + _pos[b].x * uw - p.x,
                                          si.top + _pos[b].y * uh - p.y);
            }
            continue;
        }

        if (!_stickTouch && [self stickHit:p]) {
            _stickTouch = t;
            [self updateStick:p];
            continue;
        }
        int b = [self buttonAt:p];
        if (b >= 0) {
            _assign[@((uintptr_t)t)] = @(b);
            [self refreshButtons];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIEdgeInsets si = self.safeAreaInsets;
    CGFloat uw = (w - si.left - si.right) > 1.0 ? (w - si.left - si.right) : 1.0;
    CGFloat uh = (h - si.top - si.bottom) > 1.0 ? (h - si.top - si.bottom) : 1.0;

    for (UITouch *t in touches) {
        if (_edit && t == _dragTouch) {
            CGPoint p = [t locationInView:self];
            CGFloat nx = (p.x + _dragOffset.x - si.left) / uw;
            CGFloat ny = (p.y + _dragOffset.y - si.top) / uh;
            nx = fminf(fmaxf(nx, 0.0f), 1.0f);
            ny = fminf(fmaxf(ny, 0.0f), 1.0f);
            if (_dragIdx == -2) {
                _stickPos = CGPointMake(nx, ny);
            } else if (_dragIdx >= 0) {
                _pos[_dragIdx] = CGPointMake(nx, ny);
            }
            [self setNeedsLayout];
            continue;
        }
        if (t == _stickTouch) {
            [self updateStick:[t locationInView:self]];
            continue;
        }
        NSNumber *key = @((uintptr_t)t);
        if (!_assign[key]) continue;
        int b = [self buttonAt:[t locationInView:self]];
        if (b >= 0) _assign[key] = @(b);
        else [_assign removeObjectForKey:key];
        [self refreshButtons];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches) {
        if (_edit && t == _dragTouch) {
            _dragTouch = nil;
            _dragIdx = -1;
            [self saveLayout];
            continue;
        }
        if (t == _stickTouch) {
            _stickTouch = nil;
            g_gbStickTouch[0] = 0.0f;
            g_gbStickTouch[1] = 0.0f;
            [self placeKnob:CGPointZero];
            continue;
        }
        [_assign removeObjectForKey:@((uintptr_t)t)];
        [self refreshButtons];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEnded:touches withEvent:event];
}

- (void)startDriving
{
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    fprintf(stderr, TAG "overlay driving at display rate\n");
}

- (void)onFrame
{
    gbpad_frame();
}

@end

static GBPadOverlay *g_overlay = nil;

static void gbpad_install_overlay(int attempt)
{
    if (g_overlay) return;
    if (attempt > 60) {
        fprintf(stderr, TAG "no usable window after %d tries, overlay not installed\n",
                attempt);
        return;
    }

    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
    }
    if (!win) win = [UIApplication sharedApplication].keyWindow;
    if (!win || win.bounds.size.width < 100.0 || win.bounds.size.height < 100.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ gbpad_install_overlay(attempt + 1); });
        return;
    }

    GBPadOverlay *ov = [[GBPadOverlay alloc] initWithFrame:win.bounds];
    [win addSubview:ov];
    g_overlay = ov;
    g_gbLive = 1;
    [ov startDriving];
    fprintf(stderr, TAG "overlay installed %.0fx%.0f\n",
            win.bounds.size.width, win.bounds.size.height);
}

// --- physical controller ---------------------------------------------------
// The iOS InputSystem backend is absent from this binary, so nothing hands us a
// Gamepad. Read GameController ourselves and feed the same virtual device.

// Everything below talks to the controller through the ObjC runtime, so there
// is no compile-time dependency on GameController headers or the framework.
static int gb_pressed(id pad, const char *name)
{
    if (!pad) return 0;
    id b = ((id (*)(id, SEL))objc_msgSend)(pad, sel_registerName(name));
    if (!b) return 0;
    return ((BOOL (*)(id, SEL))objc_msgSend)(b, sel_registerName("isPressed")) ? 1 : 0;
}

static float gb_axis(id owner, const char *stickName, const char *axisName)
{
    if (!owner) return 0.0f;
    id s = ((id (*)(id, SEL))objc_msgSend)(owner, sel_registerName(stickName));
    if (!s) return 0.0f;
    id a = ((id (*)(id, SEL))objc_msgSend)(s, sel_registerName(axisName));
    if (!a) return 0.0f;
    return ((float (*)(id, SEL))objc_msgSend)(a, sel_registerName("value"));
}

static void gbpad_install_gamecontroller(void)
{
    // No link-time dependency: pull the framework in on demand. iOS does not
    // load GameController by default, so objc_getClass returns nil until it is
    // mapped - and adding -framework GameController would tie the build to the
    // SDK having that framework present.
    Class gc = objc_getClass("GCController");
    if (!gc) {
        void *h = dlopen("/System/Library/Frameworks/GameController.framework/GameController",
                         RTLD_NOW);
        fprintf(stderr, TAG "GameController dlopen -> %s\n", h ? "ok" : dlerror());
        gc = objc_getClass("GCController");
    }
    if (!gc) {
        fprintf(stderr, TAG "GCController unavailable, physical pads disabled\n");
        return;
    }

    void (^attach)(id) = ^(id c) {
        id g = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("extendedGamepad"));
        if (!g) {
            fprintf(stderr, TAG "controller connected but has no extendedGamepad\n");
            return;
        }

        // Feed the same virtual device the overlay writes to, so the game only
        // ever sees one input source.
        void (^handler)(id, id) = ^(id pad, id element) {
            (void)element;
            unsigned m = 0;
            if (gb_pressed(pad, "buttonA"))     m |= 1u << GB_SOUTH;
            if (gb_pressed(pad, "buttonB"))     m |= 1u << GB_EAST;
            if (gb_pressed(pad, "buttonX"))     m |= 1u << GB_WEST;
            if (gb_pressed(pad, "buttonY"))     m |= 1u << GB_NORTH;
            if (gb_pressed(pad, "leftShoulder"))  m |= 1u << GB_LB;
            if (gb_pressed(pad, "rightShoulder")) m |= 1u << GB_RB;
            if (gb_pressed(pad, "buttonMenu"))  m |= 1u << GB_START;
            if (gb_pressed(pad, "buttonOptions")) m |= 1u << GB_SELECT;
            if (gb_pressed(pad, "dpadUp"))      m |= 1u << GB_DUP;
            if (gb_pressed(pad, "dpadDown"))    m |= 1u << GB_DDOWN;
            if (gb_pressed(pad, "dpadLeft"))    m |= 1u << GB_DLEFT;
            if (gb_pressed(pad, "dpadRight"))   m |= 1u << GB_DRIGHT;
            if (gb_pressed(pad, "leftTrigger")) m |= 1u << GB_LT;
            if (gb_pressed(pad, "rightTrigger")) m |= 1u << GB_RT;
            if (gb_pressed(pad, "leftThumbstickButton"))  m |= 1u << GB_LSTICK;
            if (gb_pressed(pad, "rightThumbstickButton")) m |= 1u << GB_RSTICK;
            g_gbHeldPad = m;

            float x = gb_axis(pad, "leftThumbstick", "xAxis");
            float y = gb_axis(pad, "leftThumbstick", "yAxis");
            float dx = gb_axis(pad, "dpad", "xAxis");
            float dy = gb_axis(pad, "dpad", "yAxis");
            if (fabsf(dx) > 0.5f) x = dx;
            if (fabsf(dy) > 0.5f) y = dy;
            if (fabsf(x) < 0.14f) x = 0.0f;
            if (fabsf(y) < 0.14f) y = 0.0f;
            g_gbStickPad[0] = x;
            g_gbStickPad[1] = y;
            g_gbPadStick = (x != 0.0f || y != 0.0f) ? 1 : 0;
        };

        ((void (*)(id, SEL, id))objc_msgSend)(c, sel_registerName("setHandlerQueue:"),
                                              dispatch_get_main_queue());
        ((void (*)(id, SEL, id))objc_msgSend)(g, sel_registerName("setValueChangedHandler:"),
                                              handler);
        fprintf(stderr, TAG "extended gamepad attached\n");
    };

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"GCControllerDidConnectNotification"
                    object:nil queue:nil
                usingBlock:^(NSNotification *n) { attach(n.object); }];
    [nc addObserverForName:@"GCControllerDidDisconnectNotification"
                    object:nil queue:nil
                usingBlock:^(NSNotification *n) {
                    (void)n;
                    g_gbHeldPad = 0;
                    g_gbStickPad[0] = g_gbStickPad[1] = 0.0f;
                    g_gbPadStick = 0;
                    fprintf(stderr, TAG "controller disconnected\n");
                }];

    SEL selControllers = sel_registerName("controllers");
    id existing = ((id (*)(id, SEL))objc_msgSend)((id)gc, selControllers);
    if (existing) {
        for (id c in (NSArray *)existing) attach(c);
    }

    SEL selDiscover = sel_registerName(
        "startWirelessControllerDiscoveryWithCompletionHandler:");
    if ([gc respondsToSelector:selDiscover])
        ((void (*)(id, SEL, id))objc_msgSend)(gc, selDiscover, nil);
    fprintf(stderr, TAG "wireless controller discovery started\n");
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
    gbpad_install_gamecontroller();
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
