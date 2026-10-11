#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

/* Reader-side hook.
 *
 * The country code that system_profiler / wdutil / CoreWLAN clients display is
 * NOT served by airportd.  SPAirPortReporter embeds the literal "IO80211CountryCode"
 * and reads it straight out of the IORegistry, from the DriverKit node
 * AppleWLANInterfaceSTA <IOUserNetworkWLAN>.  That property is derived from the
 * associated AP's 802.11d beacon and is not writable from userspace.
 *
 * So we rewrite the value at the choke points every reader goes through:
 *   - IORegistryEntryCreateCFProperty / SearchCFProperty / CreateCFProperties
 *   - -[CWInterface countryCode] / -[CWInterface countryCodeInternal]
 *
 * Only "IO80211CountryCode" is touched; every other lookup passes through
 * untouched so nothing else in the process is perturbed.
 *
 * Safety: with __DATA,__interpose, dyld redirects the symbol for every image
 * including this one.  The originals therefore come from the interpose
 * table's own `orig` slots -- the canonical, recursion-proof way to reach the
 * genuine libIOKit entry points.  dyld reads those slots to learn the
 * original but does not rewrite them, so they hold the real addresses.
 */

#define FORCED_VALUE "US"

/* IO80211.framework ships no public headers; declare the one symbol we use.
   It is resolved from the framework at link time. */
extern int Apple80211CopyValue(void *a11Ref, unsigned int key, void *options, CFTypeRef *out);

static void RLog(const char *fmt, ...);

struct interpose_entry { void *repl; void *orig; };

static CFTypeRef (*p_create)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef (*p_search)(io_registry_entry_t, io_name_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static kern_return_t (*p_create_all)(io_registry_entry_t, CFDictionaryRef *, CFAllocatorRef, IOOptionBits);

static NSString *(*orig_cc)(id, SEL);
static NSString *(*orig_cci)(id, SEL);

/* IO80211 private-framework user-client call -- this is what SPAirPortReporter
   actually uses to obtain the country code (it imports _Apple80211CopyValue).

   Prototype recovered from the call sites in SPAirPortReporter rather than
   guessed (no header ships with the framework, and the SDK .tbd has names
   only):

       bl  _Apple80211CopyValue
       cbnz w0, ...            ; returns kern_return_t in w0
       ldr  x20, [sp, #0x80]   ; out value loaded from the 4th arg slot

   i.e.  kern_return_t Apple80211CopyValue(a11Ref, key, options, CFTypeRef *out)
   with the out pointer in x3, not x2.  Declaring it with three arguments put
   the out pointer in x2 (which the caller passes as NULL), so every probe
   logged <null> and the real x3 was never propagated. */
static int (*p_a11copy)(void *, unsigned int, void *, CFTypeRef *);
static long g_a11_budget = 60;

static void log_a11_result(const char *tag, unsigned int key, int kr, CFTypeRef v) {
    if (!v) { RLog("A11 %s key=%u kr=%d -> <null>", tag, key, kr); return; }
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) {
        char b[64] = {0};
        CFStringGetCString((CFStringRef)v, b, sizeof(b), kCFStringEncodingUTF8);
        RLog("A11 %s key=%u -> CFString \"%s\"", tag, key, b);
    } else if (t == CFNumberGetTypeID()) {
        long n = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &n);
        RLog("A11 %s key=%u -> CFNumber %ld", tag, key, n);
    } else if (t == CFBooleanGetTypeID()) {
        RLog("A11 %s key=%u -> CFBoolean %d", tag, key, CFBooleanGetValue((CFBooleanRef)v));
    } else {
        RLog("A11 %s key=%u -> type=%lu", tag, key, (unsigned long)t);
    }
}

/* Forward declarations: dyld reads __DATA,__interpose at load time, before
   any constructor runs, so the replacement pointers must be static
   initializers rather than something filled in later. */
static CFTypeRef my_create(io_registry_entry_t entry, CFStringRef key,
                           CFAllocatorRef alloc, IOOptionBits opts);
static CFTypeRef my_search(io_registry_entry_t entry, io_name_t plane, CFStringRef key,
                           CFAllocatorRef alloc, IOOptionBits opts);
static kern_return_t my_create_all(io_registry_entry_t entry, CFDictionaryRef *props,
                                   CFAllocatorRef alloc, IOOptionBits opts);

static int my_a11copy(void *ref, unsigned int key, void *options, CFTypeRef *out);

__attribute__((used, section("__DATA,__interpose")))
static struct interpose_entry reader_interpose[4] = {
    { (void *)my_create,     (void *)IORegistryEntryCreateCFProperty },
    { (void *)my_search,     (void *)IORegistryEntrySearchCFProperty },
    { (void *)my_create_all, (void *)IORegistryEntryCreateCFProperties },
    { (void *)my_a11copy,    (void *)Apple80211CopyValue },
};

static void RLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    FILE *f = fopen("/tmp/opencode/READER.txt", "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}

/* Return a replacement for `val` if `key` is one we own, else `val`.
   Ownership: on replacement we consume `val` (release it) and return a new
   +1 reference, matching CF_RETURNS_RETAINED on the original API.
   Country/locale keys are always logged; everything else is only counted, so
   high-traffic keys like IO80211VirtualInterfaceRole cannot exhaust a budget
   and hide the lookup we actually care about. */
static long g_other_keys = 0;

static CFTypeRef rewrite_if_ours(CFStringRef key, CFTypeRef val) {
    if (!key) return val;
    char k[128] = {0};
    if (!CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8)) return val;

    int interesting = (strstr(k, "ountry") != NULL) || (strstr(k, "ocale") != NULL) ||
                      (strstr(k, "egulat") != NULL);
    if (!interesting) { __sync_fetch_and_add(&g_other_keys, 1); return val; }

    char cur[64] = {0};
    if (val && CFGetTypeID(val) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)val, cur, sizeof(cur), kCFStringEncodingUTF8);
    RLog("probe key=%s val=%s", k, val ? (cur[0] ? cur : "<str>") : "<null>");

    if (strcmp(k, "IO80211CountryCode") == 0 && val &&
        CFGetTypeID(val) == CFStringGetTypeID() && strcmp(cur, FORCED_VALUE) != 0) {
        CFStringRef out = CFStringCreateWithCString(kCFAllocatorDefault, FORCED_VALUE,
                                                    kCFStringEncodingUTF8);
        if (out) {
            RLog("rewrite IO80211CountryCode %s -> %s", cur, FORCED_VALUE);
            CFRelease(val);
            return out;
        }
    }
    return val;
}

static CFTypeRef my_create(io_registry_entry_t entry, CFStringRef key,
                           CFAllocatorRef alloc, IOOptionBits opts) {
    return rewrite_if_ours(key, p_create(entry, key, alloc, opts));
}

static CFTypeRef my_search(io_registry_entry_t entry, io_name_t plane, CFStringRef key,
                           CFAllocatorRef alloc, IOOptionBits opts) {
    return rewrite_if_ours(key, p_search(entry, plane, key, alloc, opts));
}

/* Bulk lookup: caller gets a whole dictionary back, so rewrite the entry
   rather than substituting the dictionary. */
static kern_return_t my_create_all(io_registry_entry_t entry, CFDictionaryRef *props,
                                   CFAllocatorRef alloc, IOOptionBits opts) {
    kern_return_t kr = p_create_all(entry, props, alloc, opts);
    if (kr != KERN_SUCCESS || !props || !*props) return kr;

    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, "IO80211CountryCode",
                                              kCFStringEncodingUTF8);
    if (!k) return kr;

    if (CFDictionaryGetValue((CFDictionaryRef)*props, k)) {
        CFStringRef us = CFStringCreateWithCString(kCFAllocatorDefault, FORCED_VALUE,
                                                   kCFStringEncodingUTF8);
        CFMutableDictionaryRef md = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, *props);
        if (md && us) {
            CFDictionarySetValue(md, k, us);
            CFRelease(*props);
            *props = md;
            md = NULL;                 /* ownership handed to caller */
            RLog("rewrite (bulk props) IO80211CountryCode -> %s", FORCED_VALUE);
        }
        if (md) CFRelease(md);
        if (us) CFRelease(us);
    }
    CFRelease(k);
    return kr;
}

/* IO80211 is loaded lazily by SPAirPortReporter and ships no linkable binary
   (its code lives in the dyld shared cache), so we link the SDK .tbd stub and
   take the genuine address from the interpose `orig` slot.  Do NOT dlsym for
   it: on this host dlsym(RTLD_NEXT, "Apple80211CopyValue") resolves back to
   our own replacement, which recursed until the thread hit the stack guard
   page (SIGBUS, depth 8336 in the crash report).

   Prototype: kern_return_t Apple80211CopyValue(ref, key, options, CFTypeRef *out),
   out pointer in x3 (recovered from the call sites, see the declaration above). */
static int (*real_a11copy)(void *, unsigned int, void *, CFTypeRef *);

/* Identification pass only -- log key + result, then let it through
   unchanged.  No rewriting until we know which key carries the country. */
static int my_a11copy(void *ref, unsigned int key, void *options, CFTypeRef *out) {
    if (!real_a11copy) real_a11copy = p_a11copy;
    if (!real_a11copy || (void *)real_a11copy == (void *)my_a11copy) {
        RLog("A11 CopyValue key=%u UNRESOLVED (refusing to recurse)", key);
        return -1;
    }

    int kr = real_a11copy(ref, key, options, out);
    if (__sync_fetch_and_sub(&g_a11_budget, 1) > 0)
        log_a11_result("CopyValue", key, kr, (out && kr == 0) ? *out : NULL);
    return kr;
}

/* ---- CoreWLAN ---- */

/* CoreWLAN returns (nil) for countryCode when the caller is not authorized
   for location services -- which is the normal case for a CLI probe.  Force
   the value unconditionally rather than only rewriting a non-nil one,
   otherwise a (nil) read passes straight through and the hook looks inert. */
static NSString *my_cc(id self, SEL _cmd) {
    NSString *r = orig_cc ? orig_cc(self, _cmd) : nil;
    if (r && [r isEqualToString:@FORCED_VALUE]) return r;
    RLog("CW -[CWInterface countryCode] %s -> %s",
         r ? [r UTF8String] : "(nil)", FORCED_VALUE);
    return @FORCED_VALUE;
}

static NSString *my_cci(id self, SEL _cmd) {
    NSString *r = orig_cci ? orig_cci(self, _cmd) : nil;
    if (r && [r isEqualToString:@FORCED_VALUE]) return r;
    RLog("CW -[CWInterface countryCodeInternal] %s -> %s",
         r ? [r UTF8String] : "(nil)", FORCED_VALUE);
    return @FORCED_VALUE;
}

/* ---- SPAirPortReporter's own model object ----
   The plugin declares its own `countryCode` property (the binary contains
   T@"NSString",&,VcountryCode and setCountryCode:), and that is what it
   ultimately prints.  Forcing the getter is signature-safe -- no guessed
   prototypes, no private-framework ABI -- and the setter is left to pass
   through so we can see the raw value the plugin was handed. */
static NSString *hook_prop_get(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @FORCED_VALUE;
}

/* Force the model's `locale` token.  The driver publishes IO80211Locale =
   "Unknown"; the plugin localizes it through
   spairport_wireless_card_locale_<token>, and only these tokens exist:
   China, Europe, France, Israel, Japan, Jordan, Thailand, USA, Worldwide.
   "USA" is the one that renders as a US card locale. */
static NSString *hook_locale_get(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"USA";
}

static void hook_prop_set(id self, SEL _cmd, id v) {
    RLog("prop -[%s setCountryCode:] orig=%s", object_getClassName(self),
         v ? [[v description] UTF8String] : "(nil)");
}

/* Pass-through logger for the sibling `locale` property, so we can see which
   value the plugin maps the driver's "Unknown" locale to before deciding
   whether to force it too.  Originals are kept per class because each model
   class has its own setter implementation. */
static struct { Class cls; void (*orig)(id, SEL, id); } g_locale_orig[8];
static int g_locale_n = 0;

static void hook_locale_set(id self, SEL _cmd, id v) {
    RLog("prop -[%s setLocale:] orig=%s", object_getClassName(self),
         v ? [[v description] UTF8String] : "(nil)");
    for (int i = 0; i < g_locale_n; i++) {
        if (g_locale_orig[i].cls == object_getClass(self) ||
            g_locale_orig[i].cls == [self class]) {
            g_locale_orig[i].orig(self, _cmd, v);
            return;
        }
    }
}

/* Find the plugin's model classes once the bundle has been loaded. */
static int scan_reader_props(void) {
    int found = 0;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return 0;
    Class *cls = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!cls) return 0;
    n = objc_getClassList(cls, n);

    SEL getsel = sel_registerName("countryCode");
    SEL setsel = sel_registerName("setCountryCode:");

    for (int i = 0; i < n; i++) {
        const char *img = class_getImageName(cls[i]);
        if (!img || !strstr(img, "SPAirPortReporter")) continue;

        Method g = class_getInstanceMethod(cls[i], getsel);
        Method s = class_getInstanceMethod(cls[i], setsel);
        if (!g || !s) continue;

        /* Only replace an object-returning getter (e.g. "@@:"), so a BOOL or
           integer `countryCode` elsewhere can never be mis-hooked. */
        const char *enc = method_getTypeEncoding(g);
        if (!enc || enc[0] != '@') continue;

        const char *senc = method_getTypeEncoding(s);
        if (!senc || senc[0] != 'v') continue;

        IMP oldg = method_setImplementation(g, (IMP)hook_prop_get);
        IMP olds = method_setImplementation(s, (IMP)hook_prop_set);
        RLog("OK prop -[%s countryCode] old=%p setter_old=%p",
             class_getName(cls[i]), (void *)oldg, (void *)olds);
        found++;

        /* The sibling `locale` property drives the "Locale:" line.  The driver
           reports IO80211Locale = "Unknown"; force it to the token the plugin
           localizes as spairport_wireless_card_locale_USA.  Logging-only at
           first would need a second round trip, so force and verify directly,
           but keep a pass-through logger on the setter for the raw value. */
        SEL locgetsel = sel_registerName("locale");
        Method lg = class_getInstanceMethod(cls[i], locgetsel);
        if (lg) {
            const char *genc = method_getTypeEncoding(lg);
            if (genc && genc[0] == '@') {
                IMP oldl = method_setImplementation(lg, (IMP)hook_locale_get);
                RLog("OK prop -[%s locale] old=%p", class_getName(cls[i]), (void *)oldl);
            }
        }

        SEL localesel = sel_registerName("setLocale:");
        Method lm = class_getInstanceMethod(cls[i], localesel);
        if (lm && g_locale_n < 8) {
            const char *lenc = method_getTypeEncoding(lm);
            IMP lim = method_getImplementation(lm);
            if (lenc && lenc[0] == 'v') {
                g_locale_orig[g_locale_n].cls = cls[i];
                g_locale_orig[g_locale_n].orig = (void (*)(id, SEL, id))lim;
                g_locale_n++;
                method_setImplementation(lm, (IMP)hook_locale_set);
                RLog("OK prop -[%s setLocale:] (logging)", class_getName(cls[i]));
            }
        }
    }
    free(cls);
    return found;
}

static void hook_method(Class c, const char *selname, IMP nw, IMP *out) {
    if (!c) { RLog("SKIP no-class for %s", selname); return; }
    Method m = class_getInstanceMethod(c, sel_registerName(selname));
    if (!m) { RLog("SKIP no-method -[%s %s]", class_getName(c), selname); return; }
    IMP old = method_setImplementation(m, nw);
    if (out) *out = old;
    RLog("OK -[%s %s]", class_getName(c), selname);
}

/* CoreWLAN and the .spreporter bundle are both loaded lazily, so neither
   CWInterface nor the plugin's model classes exist in the constructor.  Poll
   at 1ms so the swizzles land before the plugin's first read. */
static void *lazy_cw(void *arg) {
    (void)arg;
    int props_done = 0;
    for (int i = 0; i < 5000; i++) {          /* ~5s at 1ms */
        Class c = objc_getClass("CWInterface");
        if (c && !orig_cc) {
            RLog("CWInterface appeared after %d polls", i);
            hook_method(c, "countryCode",         (IMP)my_cc,  (IMP *)&orig_cc);
            hook_method(c, "countryCodeInternal", (IMP)my_cci, (IMP *)&orig_cci);
        }
        if (!props_done && scan_reader_props() > 0) props_done = 1;
        if (orig_cc && props_done) return NULL;
        usleep(1000);
    }
    if (!orig_cc) RLog("CWInterface never appeared (CoreWLAN not loaded here)");
    if (!props_done) RLog("SPAirPortReporter model class never appeared");
    return NULL;
}

__attribute__((constructor)) static void init_reader(void) {
    RLog("=== reader hook loaded in pid %d (%s) ===", (int)getpid(),
         getprogname() ? getprogname() : "?");

    p_create     = (CFTypeRef (*)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits))
                        reader_interpose[0].orig;
    p_search     = (CFTypeRef (*)(io_registry_entry_t, io_name_t, CFStringRef, CFAllocatorRef, IOOptionBits))
                        reader_interpose[1].orig;
    p_create_all = (kern_return_t (*)(io_registry_entry_t, CFDictionaryRef *, CFAllocatorRef, IOOptionBits))
                        reader_interpose[2].orig;
    p_a11copy    = (int (*)(void *, unsigned int, void *, CFTypeRef *))
                        reader_interpose[3].orig;
    RLog("interpose origs create=%p search=%p create_all=%p a11copy=%p",
         (void *)p_create, (void *)p_search, (void *)p_create_all, (void *)p_a11copy);

    hook_method(objc_getClass("CWInterface"), "countryCode",         (IMP)my_cc,  (IMP *)&orig_cc);
    hook_method(objc_getClass("CWInterface"), "countryCodeInternal", (IMP)my_cci, (IMP *)&orig_cci);

    pthread_t th;
    if (pthread_create(&th, NULL, lazy_cw, NULL) == 0) pthread_detach(th);
}

__attribute__((destructor)) static void fini_reader(void) {
    RLog("=== reader hook unloading in pid %d (non-country lookups=%ld) ===",
         (int)getpid(), g_other_keys);
}
