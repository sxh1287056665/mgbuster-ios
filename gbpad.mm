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
//   symbols including InitializeGameControllers() and
//   GetGameControllerData(GCController*). But that path feeds Unity's *legacy*
//   input, and Input System never reads legacy joysticks.
//
//   So the bridge is built here: talk to the IL2CPP runtime directly, ask the
//   Input System to instantiate a Gamepad, and later push state into it.
//
// STAGE 1 (this file, first build)
//   - prove the IL2CPP API is reachable from inside UnityFramework
//   - dump the exact field layout of every type stage 2 needs
//   - create one Gamepad device and report whether it took
//   Nothing is fed into the device yet; this build only has to answer "does the
//   runtime let us do this at all", and hand back the offsets.
//
// Everything prints to stderr, which the app already redirects into the boot
// log, so no new logging plumbing is needed.
// =============================================================================

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define TAG "[gbpad] "

// --- minimal IL2CPP type surface -------------------------------------------
// Opaque handles only. We never dereference these ourselves; every access goes
// through an exported il2cpp_* call so the layout stays the runtime's business.
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
static const char *(*f_class_get_name)(Il2CppClass *);
static const char *(*f_class_get_namespace)(Il2CppClass *);
static Il2CppObject *(*f_thread_attach)(Il2CppDomain *);

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
    BIND(class_get_name);
    BIND(class_get_namespace);
    BIND(thread_attach);
    return 1;
}
#undef BIND

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
    fprintf(stderr, TAG "fields of %s::%s\n",
            f_class_get_namespace(klass), f_class_get_name(klass));
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

// --- stage 1 ---------------------------------------------------------------

static int stage1(void)
{
    Il2CppDomain *domain = f_domain_get();
    if (!domain) return 0;  // runtime not up yet, caller retries

    f_thread_attach(domain);
    fprintf(stderr, TAG "domain up, thread attached\n");

    Il2CppImage *img = find_image(domain, "Unity.InputSystem");
    if (!img) return -1;  // fatal, no point retrying

    Il2CppClass *cGamepad = f_class_from_name(img, "UnityEngine.InputSystem", "Gamepad");
    Il2CppClass *cDevice = f_class_from_name(img, "UnityEngine.InputSystem", "InputDevice");
    Il2CppClass *cSys = f_class_from_name(img, "UnityEngine.InputSystem", "InputSystem");
    Il2CppClass *cStateBlock = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "InputStateBlock");
    Il2CppClass *cGamepadState = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "GamepadState");
    Il2CppClass *cBuffers = f_class_from_name(img, "UnityEngine.InputSystem.LowLevel", "InputStateBuffers");

    fprintf(stderr, TAG "class Gamepad        %s\n", cGamepad ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputDevice    %s\n", cDevice ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputSystem    %s\n", cSys ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputStateBlock %s\n", cStateBlock ? "ok" : "MISSING");
    fprintf(stderr, TAG "class GamepadState   %s\n", cGamepadState ? "ok" : "MISSING");
    fprintf(stderr, TAG "class InputStateBuffers %s\n", cBuffers ? "ok" : "MISSING");

    // Layout dump: stage 2 writes GamepadState bytes into the device's state
    // buffer, so these offsets are the whole contract.
    dump_fields(cStateBlock, "InputStateBlock");
    dump_fields(cGamepadState, "GamepadState");
    dump_fields(cDevice, "InputDevice");
    dump_methods(cSys, "InputSystem", "AddDevice");
    dump_methods(cSys, "InputSystem", "QueueState");
    dump_methods(cSys, "InputSystem", "Update");

    if (!cSys) return -1;

    // AddDevice(string layout, string name, InputDevice deviceToCopyFrom)
    MethodInfo *add = f_class_get_method_from_name(cSys, "AddDevice", 3);
    if (!add) {
        fprintf(stderr, TAG "AddDevice/3 not found, trying AddDevice/1\n");
        add = f_class_get_method_from_name(cSys, "AddDevice", 1);
    }
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
        fprintf(stderr, TAG "AddDevice threw (exception ptr %p)\n", (void *)exc);
        return -1;
    }
    if (!dev) {
        fprintf(stderr, TAG "AddDevice returned null\n");
        return -1;
    }

    fprintf(stderr, TAG "GAMEPAD CREATED at %p\n", (void *)dev);

    // Confirm it is reachable as Gamepad.current - that is what the game's
    // <Gamepad> bindings resolve against.
    MethodInfo *getCurrent = f_class_get_method_from_name(cGamepad, "get_current", 0);
    if (getCurrent) {
        Il2CppException *e2 = NULL;
        Il2CppObject *cur = f_runtime_invoke(getCurrent, NULL, NULL, &e2);
        fprintf(stderr, TAG "Gamepad.current -> %p%s\n", (void *)cur,
                (cur == dev) ? "  (matches the new device)" : "");
    } else {
        fprintf(stderr, TAG "Gamepad::get_current not found\n");
    }

    return 1;
}

// --- bootstrap -------------------------------------------------------------

static void *worker(void *unused)
{
    (void)unused;
    // GameAssembly and the Input System come up some way into startUnity:, and
    // the runtime is not queryable before that. Poll rather than guess a delay.
    for (int i = 0; i < 150; i++) {
        if (!f_domain_get) {
            if (!bind_api()) {
                fprintf(stderr, TAG "IL2CPP API unreachable from UnityFramework\n");
                return NULL;
            }
            fprintf(stderr, TAG "IL2CPP API bound\n");
        }
        int r = stage1();
        if (r == 1) {
            fprintf(stderr, TAG "stage 1 complete\n");
            return NULL;
        }
        if (r < 0) {
            fprintf(stderr, TAG "stage 1 failed, giving up\n");
            return NULL;
        }
        usleep(200 * 1000);
    }
    fprintf(stderr, TAG "timed out waiting for the IL2CPP domain\n");
    return NULL;
}

__attribute__((constructor))
static void gbpad_init(void)
{
    fprintf(stderr, TAG "loaded\n");
    // GameAssembly is a dependency of UnityFramework, so its exported il2cpp_*
    // symbols should already be in the global scope. If not, load it by hand.
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
