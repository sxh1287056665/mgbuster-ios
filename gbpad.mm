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
//   The first version of this file polled il2cpp_domain_get() from a thread
//   started in a constructor. That killed the app 24 ms after launch: before
//   il2cpp_init() runs, il2cpp_domain_get() does not return NULL, it returns
//   uninitialised memory, and il2cpp_thread_attach() dereferences it.
//
//   The runtime is therefore never touched until il2cpp_init() has actually
//   returned. We learn that by interposing il2cpp_init: UnityFramework imports
//   it as an undefined symbol, so dyld redirects the engine's call through us.
//   A long timeout remains as a backstop in case interposing ever stops
//   matching, because by then the runtime is certainly up anyway.
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

// Set only after the real il2cpp_init() has returned.
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

// --- il2cpp_init interposition ---------------------------------------------
// UnityFramework imports il2cpp_init as an undefined symbol, so dyld routes the
// engine's call here. Waiting for this is the only reliable "the runtime is
// usable" signal; see the timing note at the top of the file.

extern "C" int il2cpp_init(const char *domain_name);
extern "C" int il2cpp_init_utf16(const uint16_t *domain_name);

static int (*orig_il2cpp_init)(const char *);
static int (*orig_il2cpp_init_utf16)(const uint16_t *);

static int hook_il2cpp_init(const char *domain_name)
{
    if (!orig_il2cpp_init)
        orig_il2cpp_init = (int (*)(const char *))dlsym(RTLD_NEXT, "il2cpp_init");
    int rc = orig_il2cpp_init ? orig_il2cpp_init(domain_name) : -1;
    fprintf(stderr, TAG "il2cpp_init returned %d - runtime usable\n", rc);
    g_il2cpp_ready = 1;
    return rc;
}

static int hook_il2cpp_init_utf16(const uint16_t *domain_name)
{
    if (!orig_il2cpp_init_utf16)
        orig_il2cpp_init_utf16 = (int (*)(const uint16_t *))dlsym(RTLD_NEXT, "il2cpp_init_utf16");
    int rc = orig_il2cpp_init_utf16 ? orig_il2cpp_init_utf16(domain_name) : -1;
    fprintf(stderr, TAG "il2cpp_init_utf16 returned %d - runtime usable\n", rc);
    g_il2cpp_ready = 1;
    return rc;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)(uintptr_t)&hook_il2cpp_init,       (const void *)(uintptr_t)&il2cpp_init },
    { (const void *)(uintptr_t)&hook_il2cpp_init_utf16, (const void *)(uintptr_t)&il2cpp_init_utf16 },
};

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

// Search a class and its ancestors for a method. ReadValue lives on the
// generic base InputControl<TValue>, not on StickControl itself, so a plain
// lookup on the concrete class comes back empty.
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

static int g_stateBlockOff = -1;   // InputDevice.m_StateBlock
static int g_fmtOff = -1;          // InputStateBlock.format
static int g_byteOffOff = -1;      // InputStateBlock.byteOffset
static int g_sizeBitsOff = -1;     // InputStateBlock.sizeInBits
static int g_deviceIdOff = -1;     // InputDevice.m_DeviceId
static int g_stateBlockSize = 0;

static int g_evTypeOff = -1;       // InputEvent.m_Type
static int g_evSizeOff = -1;       // InputEvent.m_SizeInBytes
static int g_evDeviceOff = -1;     // InputEvent.m_DeviceId
static int g_stFormatOff = -1;     // StateEvent.stateFormat
static int g_stSizeOff = -1;       // StateEvent.stateSizeInBytes
static int g_stOffsetOff = -1;     // StateEvent.stateOffset
static int g_stTotalSize = 0;      // StateEvent value size == payload offset

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
    g_cInputEvent = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "InputEvent");
    g_cStateEvent = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "StateEvent");
    g_cStick      = f_class_from_name(img, "UnityEngine.InputSystem.Controls", "StickControl");

    fprintf(stderr, TAG "class Gamepad         %s\n", g_cGamepad ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputDevice     %s\n", cDevice ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputSystem     %s\n", g_cSys ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputStateBlock %s\n", g_cStateBlock ? "ok" : "MISSING");
    fprintf(stderr, TAG "class GamepadState    %s\n", cGamepadState ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputEvent      %s\n", g_cInputEvent ? "ok" : "MISSING");
    fprintf(stderr, TAG "class StateEvent      %s\n", g_cStateEvent ? "ok" : "MISSING");
    fprintf(stderr, TAG "class StickControl    %s\n", g_cStick ? "ok" : "MISSING");

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

    uint32_t align = 0;
    g_stateBlockOff = field_off(cDevice, "m_StateBlock");
    g_deviceIdOff   = field_off(cDevice, "m_DeviceId");
    g_fmtOff        = field_off(g_cStateBlock, "format");
    g_byteOffOff    = field_off(g_cStateBlock, "byteOffset");
    g_sizeBitsOff   = field_off(g_cStateBlock, "sizeInBits");
    g_stateBlockSize = f_class_value_size(g_cStateBlock, &align);

    g_evTypeOff   = field_off(g_cInputEvent, "m_Type");
    g_evSizeOff   = field_off(g_cInputEvent, "m_SizeInBytes");
    g_evDeviceOff = field_off(g_cInputEvent, "m_DeviceId");
    g_stFormatOff = field_off(g_cStateEvent, "stateFormat");
    g_stSizeOff   = field_off(g_cStateEvent, "stateSizeInBytes");
    g_stOffsetOff = field_off(g_cStateEvent, "stateOffset");
    g_stTotalSize = f_class_value_size(g_cStateEvent, &align);

    fprintf(stderr, TAG "resolved device: m_StateBlock@%d(size %d) m_DeviceId@%d\n",
            g_stateBlockOff, g_stateBlockSize, g_deviceIdOff);
    fprintf(stderr, TAG "resolved block : format@%d byteOffset@%d sizeInBits@%d\n",
            g_fmtOff, g_byteOffOff, g_sizeBitsOff);
    fprintf(stderr, TAG "resolved event : m_Type@%d m_SizeInBytes@%d m_DeviceId@%d\n",
            g_evTypeOff, g_evSizeOff, g_evDeviceOff);
    fprintf(stderr, TAG "resolved state : stateFormat@%d stateSizeInBytes@%d stateOffset@%d total=%d\n",
            g_stFormatOff, g_stSizeOff, g_stOffsetOff, g_stTotalSize);

    if (g_stateBlockOff < 0 || g_deviceIdOff < 0 || g_fmtOff < 0 ||
        g_byteOffOff < 0 || g_sizeBitsOff < 0 || g_stateBlockSize <= 0 ||
        g_evTypeOff < 0 || g_evSizeOff < 0 || g_evDeviceOff < 0 ||
        g_stFormatOff < 0 || g_stSizeOff < 0 || g_stOffsetOff < 0 || g_stTotalSize <= 0) {
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

    Il2CppString *sLayout = f_string_new("Gamepad");
    Il2CppString *sName = f_string_new("GBPad");
    Il2CppException *exc = NULL;
    Il2CppObject *dev = NULL;
    if (f_method_get_param_count(add) >= 3) {
        void *args[3] = { sLayout, sName, NULL };
        dev = f_runtime_invoke(add, NULL, args, &exc);
    } else {
        void *args[1] = { sLayout };
        dev = f_runtime_invoke(add, NULL, args, &exc);
    }
    if (exc) {
        fprintf(stderr, TAG "AddDevice threw (exception %p)\n", (void *)exc);
        return -1;
    }
    if (!dev) {
        fprintf(stderr, TAG "AddDevice returned null\n");
        return -1;
    }
    g_device = dev;
    fprintf(stderr, TAG "GAMEPAD CREATED at %p\n", (void *)dev);

    MethodInfo *getCurrent = f_class_get_method_from_name(g_cGamepad, "get_current", 0);
    if (getCurrent) {
        Il2CppException *e2 = NULL;
        Il2CppObject *cur = f_runtime_invoke(getCurrent, NULL, NULL, &e2);
        fprintf(stderr, TAG "Gamepad.current -> %p%s\n", (void *)cur,
                (cur == dev) ? "  (matches the new device)" : "");
    }
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

    uint32_t stateBytes = (sizeInBits + 7) / 8;
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

    // StateEvent's declared size is exactly where the payload begins.
    const int kPayload = g_stTotalSize;
    unsigned char *ev = (unsigned char *)calloc(1, kPayload + stateBytes);
    if (!ev) return -1;

    uint32_t total = (uint32_t)(kPayload + stateBytes);
    memcpy(ev + g_evTypeOff, &evType, 4);
    uint16_t sz16 = (uint16_t)total;
    memcpy(ev + g_evSizeOff, &sz16, 2);
    memcpy(ev + g_evDeviceOff, &devId, 4);
    memcpy(ev + g_stFormatOff, &fmt, 4);
    memcpy(ev + g_stSizeOff, &stateBytes, 4);
    uint32_t payloadOff = (uint32_t)kPayload;
    memcpy(ev + g_stOffsetOff, &payloadOff, 4);

    // Synthetic pattern: leftStick pushed to +X. GamepadState keeps leftStick
    // as its first two floats.
    float *state = (float *)(ev + kPayload);
    state[0] = 0.60f;
    state[1] = 0.00f;

    MethodInfo *queue = f_class_get_method_from_name(g_cSys, "QueueEvent", 1);
    if (!queue) {
        fprintf(stderr, TAG "InputSystem.QueueEvent/1 not found\n");
        free(ev);
        return -1;
    }

    void *eventPtrValue = ev;
    void *args[1] = { &eventPtrValue };
    Il2CppException *exc = NULL;
    f_runtime_invoke(queue, NULL, args, &exc);
    if (exc) {
        fprintf(stderr, TAG "QueueEvent threw (exception %p)\n", (void *)exc);
        free(ev);
        return -1;
    }
    fprintf(stderr, TAG "QUEUED type=0x%08x dev=%d stateBytes=%u leftStick=(%.2f,%.2f)\n",
            evType, devId, stateBytes, state[0], state[1]);
    free(ev);

    // Let the player loop consume the event. Calling InputSystem.Update() from
    // this thread would race the front/back state-buffer swap.
    usleep(150 * 1000);

    // Read back through the managed API - the proof the chain works, with no
    // controller involved and no gameplay side effects beyond the stick value.
    MethodInfo *getCurrent = f_class_get_method_from_name(g_cGamepad, "get_current", 0);
    MethodInfo *getStick = f_class_get_method_from_name(g_cGamepad, "get_leftStick", 0);
    MethodInfo *readObj = g_cStick ? find_method_up(g_cStick, "ReadValueAsObject", 0, 12) : NULL;

    if (!getCurrent || !getStick || !readObj) {
        fprintf(stderr, TAG "readback unavailable (get_current=%p get_leftStick=%p ReadValueAsObject=%p)\n",
                (void *)getCurrent, (void *)getStick, (void *)readObj);
        return 0;
    }

    Il2CppException *e1 = NULL;
    Il2CppObject *cur = f_runtime_invoke(getCurrent, NULL, NULL, &e1);
    if (!cur || e1) {
        fprintf(stderr, TAG "readback: Gamepad.current null\n");
        return 0;
    }
    Il2CppException *e2 = NULL;
    Il2CppObject *stick = f_runtime_invoke(getStick, cur, NULL, &e2);
    if (!stick || e2) {
        fprintf(stderr, TAG "readback: leftStick control null\n");
        return 0;
    }
    Il2CppException *e3 = NULL;
    Il2CppObject *boxed = f_runtime_invoke(readObj, stick, NULL, &e3);
    if (!boxed || e3) {
        fprintf(stderr, TAG "readback: ReadValueAsObject failed\n");
        return 0;
    }
    // Boxed Vector2: il2cpp object header (klass*, monitor) then the value.
    float *v = (float *)((unsigned char *)boxed + 2 * sizeof(void *));
    fprintf(stderr, TAG "READBACK leftStick = (%.3f, %.3f)%s\n", v[0], v[1],
            (v[0] > 0.5f) ? "   <== INJECTION WORKS" : "   <== did not take");
    return 0;
}

// --- bootstrap -------------------------------------------------------------

static void *worker(void *unused)
{
    (void)unused;

    // Never touch the runtime before il2cpp_init has returned. 25 s is a
    // backstop only; interposing should always fire first.
    int waited = 0;
    while (!g_il2cpp_ready && waited < 250) { usleep(100 * 1000); waited++; }
    if (!g_il2cpp_ready)
        fprintf(stderr, TAG "interpose never fired after %d ms, probing anyway\n", waited * 100);
    else
        fprintf(stderr, TAG "runtime ready after ~%d ms\n", waited * 100);

    usleep(500 * 1000);   // let the domain finish coming up

    if (!bind_api()) {
        fprintf(stderr, TAG "IL2CPP API unreachable from UnityFramework\n");
        return NULL;
    }
    fprintf(stderr, TAG "IL2CPP API bound\n");

    for (int i = 0; i < 40; i++) {
        int r = stage1();
        if (r == 1) break;
        if (r < 0) { fprintf(stderr, TAG "stage 1 failed, stopping\n"); return NULL; }
        usleep(250 * 1000);
    }
    if (!g_device) {
        fprintf(stderr, TAG "no device after retries, stopping\n");
        return NULL;
    }
    fprintf(stderr, TAG "stage 1 complete\n");

    usleep(1500 * 1000);   // let the scene finish loading before feeding state
    stage2();
    fprintf(stderr, TAG "stage 2 done\n");
    return NULL;
}

__attribute__((constructor))
static void gbpad_init(void)
{
    fprintf(stderr, TAG "loaded (interpose armed)\n");
    if (!dlsym(RTLD_DEFAULT, "il2cpp_domain_get")) {
        fprintf(stderr, TAG "il2cpp symbols not global, dlopen GameAssembly\n");
        dlopen("@rpath/GameAssembly.framework/GameAssembly", RTLD_NOW | RTLD_GLOBAL);
    }
    pthread_t t;
    if (pthread_create(&t, NULL, worker, NULL) == 0)
        pthread_detach(t);
    else
        fprintf(stderr, TAG "pthread_create failed\n");
}
