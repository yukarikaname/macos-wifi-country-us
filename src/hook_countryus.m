#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>

static os_log_t glog;
#define FORCED @"US"

static void SwzLog(const char *fmt, ...);

/* ---------- countryd side (RegulatoryDomain) ---------- */
static NSString *(*orig_initCC)(id, SEL, NSString *, unsigned, id, char);
static id (*orig_initCoder)(id, SEL, id);
static NSString *(*orig_countryCode)(id, SEL);
static id (*orig_combined)(id, SEL);
static id (*orig_lastknown)(id, SEL);

/* ---------- airportd side ---------- */
static NSString *(*orig_qryCC)(id, SEL, id, id, NSError **);
static void (*orig_updRD)(id, SEL, id, BOOL);
static void (*orig_updRDd)(id, SEL, id, BOOL);
static void (*orig_detRD)(id, SEL, id);
static void (*orig_p2pCC)(id, SEL, id);
static void (*orig_scanCC)(id, SEL);
static void (*orig_scanCCu)(id, SEL);
static void (*orig_scanCCs)(id, SEL);
static void (*orig_trigCC)(id, SEL);
static void (*orig_setCCsrc)(id, SEL, id, int);
static void (*orig_retryCCsrc)(id, SEL, id, int);
static void (*orig_setLocaleCC)(id, SEL, id);
static BOOL (*orig_setDevCC)(id, SEL, id);

static void WriteMarker(const char *what) {
    FILE *f = fopen("/tmp/opencode/HOOK_LOADED", "a");
    if (f) { fprintf(f, "pid=%d proc=%s %s\n", getpid(), getprogname(), what); fclose(f); }
}

/* Only ever act inside the two daemons we care about. The dylib is installed
   system-wide via launchctl setenv, so every launchd child loads it; swizzling
   arbitrary system daemons would be reckless. */
static int ShouldHook(void) {
    const char *p = getprogname();
    if (!p) return 0;
    if (strncmp(p, "airport", 7) == 0) return 1;   /* airportd, airportd.copy */
    if (strcmp(p, "countryd") == 0) return 1;
    if (strncmp(p, "t1", 2) == 0) return 1;         /* unit-test harness */
    if (access("/tmp/opencode/HOOK_ALL", F_OK) == 0) return 1;
    return 0;
}

/* ---------------- ivar forcing ---------------- */

static void ForceIvar(id self, const char *name, const char *tag) {
    if (!self) return;
    Ivar iv = class_getInstanceVariable(object_getClass(self), name);
    if (!iv) return;
    NSString *cur = nil;
    @try { cur = object_getIvar(self, iv); } @catch (id e) { return; }
    if (cur && [cur isKindOfClass:[NSString class]] && [cur isEqualToString:FORCED]) return;
    @try { object_setIvar(self, iv, (id)FORCED); }
    @catch (id e) { os_log(glog, "setIvar %{public}s failed", tag); return; }
    os_log(glog, "%{public}s %{public}s %{public}s -> US", tag, name,
           cur ? [(NSString *)cur UTF8String] : "(nil)");
}

/* ---------------- countryd hooks ---------------- */

static NSString *hook_initCC(id self, SEL _cmd, NSString *cc, unsigned prio, id ts, char disputed) {
    return orig_initCC(self, _cmd, FORCED, prio, ts, disputed);
}

static id hook_initCoder(id self, SEL _cmd, id coder) {
    id r = orig_initCoder(self, _cmd, coder);
    if (r) ForceIvar(r, "_countryCode", "initCoder");
    return r;
}

static NSString *hook_countryCode(id self, SEL _cmd) {
    NSString *r = orig_countryCode ? orig_countryCode(self, _cmd) : nil;
    if (r && [r isEqualToString:FORCED]) return r;
    os_log(glog, "countryCode %{public}s -> US", r ? [r UTF8String] : "(nil)");
    return FORCED;
}

static id SynthArray(void) {
    Class E = objc_getClass("RDEstimate");
    if (!E) return nil;
    SEL init = sel_registerName("initWithCountryCode:priority:timestamp:inDisputedArea:");
    id (*send)(id, SEL, NSString *, unsigned, id, char) =
        (id (*)(id, SEL, NSString *, unsigned, id, char))objc_msgSend;
    id est = send([E alloc], init, FORCED, 5u, [NSDate date], (char)0);
    if (!est) return nil;
    return [NSArray arrayWithObject:est];
}

static id hook_combined(id self, SEL _cmd) {
    id e = orig_combined ? orig_combined(self, _cmd) : nil;
    if (e) return e;
    os_log(glog, "getCombinedEstimate nil -> synthesized US");
    return SynthArray();
}

static id hook_lastknown(id self, SEL _cmd) {
    id e = orig_lastknown ? orig_lastknown(self, _cmd) : nil;
    if (e) return e;
    os_log(glog, "getLastKnownCombinedEstimate nil -> synthesized US");
    return SynthArray();
}

/* ---------------- airportd hooks ---------------- */

/* XPC getter that answers wdutil / system_profiler / ControlCenter. */
static NSString *hook_qryCC(id self, SEL _cmd, id name, id conn, NSError **err) {
    NSString *r = orig_qryCC ? orig_qryCC(self, _cmd, name, conn, err) : nil;
    if (r && [r isEqualToString:FORCED]) return r;
    os_log(glog, "queryCountryCode %{public}s -> US", r ? [r UTF8String] : "(nil)");
    return FORCED;
}

static void ForceRD(id self) { ForceIvar(self, "_rdCountryCode", "rd"); }

static void hook_updRD(id self, SEL _cmd, id cc, BOOL force) {
    SwzLog("updRD orig=%s force=%d", cc ? [[cc description] UTF8String] : "(nil)", (int)force);
    if (orig_updRD) orig_updRD(self, _cmd, FORCED, force);
    ForceRD(self);
}

static void hook_updRDd(id self, SEL _cmd, id cc, BOOL force) {
    SwzLog("updRDd orig=%s force=%d", cc ? [[cc description] UTF8String] : "(nil)", (int)force);
    if (orig_updRDd) orig_updRDd(self, _cmd, FORCED, force);
    ForceRD(self);
}

/* The single `id` arg's semantics are not established; keep it, force after. */
static void hook_detRD(id self, SEL _cmd, id arg) {
    if (orig_detRD) orig_detRD(self, _cmd, arg);
    ForceRD(self);
}

static void hook_p2pCC(id self, SEL _cmd, id cc) {
    if (orig_p2pCC) orig_p2pCC(self, _cmd, FORCED);
    ForceRD(self);
}

static void hook_scanCC(id self, SEL _cmd)  { if (orig_scanCC)  orig_scanCC(self, _cmd);  ForceRD(self); }
static void hook_scanCCu(id self, SEL _cmd) { if (orig_scanCCu) orig_scanCCu(self, _cmd); ForceRD(self); }
static void hook_scanCCs(id self, SEL _cmd) { if (orig_scanCCs) orig_scanCCs(self, _cmd); ForceRD(self); }
static void hook_trigCC(id self, SEL _cmd)  { if (orig_trigCC)  orig_trigCC(self, _cmd);  ForceRD(self); }

static void hook_setCCsrc(id self, SEL _cmd, id cc, int src) {
    SwzLog("setCCsrc orig=%s src=%d", cc ? [[cc description] UTF8String] : "(nil)", src);
    if (orig_setCCsrc) orig_setCCsrc(self, _cmd, FORCED, src);
}

static void hook_retryCCsrc(id self, SEL _cmd, id cc, int src) {
    SwzLog("retryCCsrc orig=%s src=%d", cc ? [[cc description] UTF8String] : "(nil)", src);
    if (orig_retryCCsrc) orig_retryCCsrc(self, _cmd, FORCED, src);
}

static void hook_setLocaleCC(id self, SEL _cmd, id cc) {
    SwzLog("setLocaleCC orig=%s", cc ? [[cc description] UTF8String] : "(nil)");
    if (orig_setLocaleCC) orig_setLocaleCC(self, _cmd, FORCED);
}

/* -[WiFiLocaleManagerUser setDeviceCountryCode:] -> C24@0:8@16 (BOOL).
   This is the most likely "push to device/driver" path; log the incoming
   value so we can see whether it is ever consulted, then force US. */
static BOOL hook_setDevCC(id self, SEL _cmd, id cc) {
    SwzLog("setDeviceCountryCode orig=%s", cc ? [[cc description] UTF8String] : "(nil)");
    return orig_setDevCC ? orig_setDevCC(self, _cmd, FORCED) : NO;
}

/* Pure queries: answer US without calling through. */
static NSString *hook_str0(id self, SEL _cmd) { return FORCED; }

/* ---------------- swizzle helpers ---------------- */

/* os_log is unreliable on this host (the log store returns nothing), so mirror
   every swizzle outcome to a file we can read back over ssh. */
static void SwzLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    FILE *f = fopen("/tmp/opencode/SWIZZLE.txt", "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}

static IMP SwizzleTyped(Class c, SEL sel, IMP nw, const char *wantEnc) {
    if (!c) { SwzLog("SKIP no-class %s", sel_getName(sel)); return NULL; }
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { SwzLog("SKIP no-method -[%s %s]", class_getName(c), sel_getName(sel)); return NULL; }
    const char *enc = method_getTypeEncoding(m);
    if (wantEnc && enc && strcmp(enc, wantEnc) != 0) {
        SwzLog("SKIP enc-mismatch -[%s %s] got=%s want=%s",
               class_getName(c), sel_getName(sel), enc, wantEnc);
        return NULL;
    }
    IMP old = method_setImplementation(m, nw);
    SwzLog("OK -[%s %s]", class_getName(c), sel_getName(sel));
    return old;
}

static IMP Swizzle(Class c, SEL sel, IMP nw) { return SwizzleTyped(c, sel, nw, NULL); }

/* ---------------- reply-block path (system_profiler / wdutil) ---------------- */

static void (*orig_qryCCr)(id, SEL, id, id);

/* Read a block's type encoding from its descriptor, so the client's reply
   signature can be learned instead of guessed. */
static const char *BlockSig(id blk) {
    if (!blk) return NULL;
    unsigned char *b = (unsigned char *)blk;
    uint32_t flags;
    memcpy(&flags, b + 8, sizeof(flags));
    if (!(flags & (1u << 30))) return NULL;              /* BLOCK_HAS_SIGNATURE */
    uintptr_t *d = *(uintptr_t **)(b + 24);
    if (!d) return NULL;
    if (flags & (1u << 25)) return (const char *)d[4];    /* copy+dispose present */
    return (const char *)d[2];
}

static void hook_qryCCr(id self, SEL _cmd, id name, id reply) {
    const char *sig = BlockSig(reply);
    SwzLog("REPLYQ -[%s %s] iface=%s blkenc=%s",
           class_getName(object_getClass(self)), sel_getName(_cmd),
           name ? [[name description] UTF8String] : "(nil)",
           sig ? sig : "(none)");
    if (orig_qryCCr) orig_qryCCr(self, _cmd, name, reply);
}

#define ENC_GET0  "@16@0:8"
#define ENC_SET1  "v24@0:8@16"
#define ENC_SET2I "v28@0:8@16i24"
#define ENC_FORCE "v28@0:8@16B24"

__attribute__((constructor))
static void countryus_init(void) {
    glog = os_log_create("com.user.countryus", "hook");

    if (!ShouldHook()) return;
    WriteMarker("loaded");

    dlopen("/System/Library/PrivateFrameworks/RegulatoryDomain.framework/RegulatoryDomain",
           RTLD_LAZY | RTLD_GLOBAL);

    /* --- countryd --- */
    Class est = objc_getClass("RDEstimate");
    Class ccd = objc_getClass("RDCachedData");
    if (est) {
        orig_initCC = (void *)Swizzle(est,
            sel_registerName("initWithCountryCode:priority:timestamp:inDisputedArea:"),
            (IMP)hook_initCC);
        orig_initCoder = (void *)Swizzle(est, sel_registerName("initWithCoder:"),
                                         (IMP)hook_initCoder);
        orig_countryCode = (void *)Swizzle(est, sel_registerName("countryCode"),
                                           (IMP)hook_countryCode);
    } else {
        WriteMarker("no_RDEstimate");
    }
    if (ccd) {
        orig_combined = (void *)Swizzle(ccd, sel_registerName("getCombinedEstimate"),
                                        (IMP)hook_combined);
        orig_lastknown = (void *)Swizzle(ccd, sel_registerName("getLastKnownCombinedEstimate"),
                                         (IMP)hook_lastknown);
    } else {
        WriteMarker("no_RDCachedData");
    }

    /* --- airportd --- */
    Class subsys = objc_getClass("CWXPCSubsystem");
    Class ctx    = objc_getClass("CWXPCInterfaceContext");
    Class mgr    = objc_getClass("WiFiLocaleManager");
    Class mgru   = objc_getClass("WiFiLocaleManagerUser");

    if (subsys) {
        orig_qryCC = (void *)SwizzleTyped(subsys,
            sel_registerName("queryCountryCodeForInterfaceWithName:connection:error:"),
            (IMP)hook_qryCC, "@40@0:8@16@24^@32");
    }

    /* Reply-block path: this is what client tools (system_profiler, wdutil,
       ControlCenter) use. Probe only for now -- log entry + block signature. */
    {
        Class conn = objc_getClass("CWXPCConnection");
        if (conn) orig_qryCCr = (void *)SwizzleTyped(conn,
            sel_registerName("queryCountryCodeForInterfaceWithName:reply:"),
            (IMP)hook_qryCCr, "v32@0:8@16@?24");
    }

    if (ctx) {
        orig_updRD   = (void *)SwizzleTyped(ctx, sel_registerName("updateCountryCodeForRegulatoryDomain:force:"),   (IMP)hook_updRD,   ENC_FORCE);
        orig_updRDd  = (void *)SwizzleTyped(ctx, sel_registerName("__updateCountryCodeForRegulatoryDomain:force:"), (IMP)hook_updRDd,  ENC_FORCE);
        orig_detRD   = (void *)SwizzleTyped(ctx, sel_registerName("__determineCountryCodeForRegulatoryDomain:"),    (IMP)hook_detRD,   ENC_SET1);
        orig_p2pCC   = (void *)SwizzleTyped(ctx, sel_registerName("updateP2PCountryCode:"),                         (IMP)hook_p2pCC,   ENC_SET1);
        orig_scanCC  = (void *)SwizzleTyped(ctx, sel_registerName("updateCountryCodeFromScanCache"),                (IMP)hook_scanCC,  "v16@0:8");
        orig_scanCCu = (void *)SwizzleTyped(ctx, sel_registerName("__updateCountryCodeFromScanCache"),              (IMP)hook_scanCCu, "v16@0:8");
        orig_scanCCs = (void *)SwizzleTyped(ctx, sel_registerName("updateCountryCodeFromScanCacheSync"),            (IMP)hook_scanCCs, "v16@0:8");
        orig_trigCC  = (void *)SwizzleTyped(ctx, sel_registerName("triggerCountryCodeDetermination"),               (IMP)hook_trigCC,  "v16@0:8");
    }

    if (mgr) {
        orig_setCCsrc   = (void *)SwizzleTyped(mgr, sel_registerName("setCountryCode:source:"),    (IMP)hook_setCCsrc,   ENC_SET2I);
        orig_retryCCsrc = (void *)SwizzleTyped(mgr, sel_registerName("retrySetCountryCode:source:"), (IMP)hook_retryCCsrc, ENC_SET2I);
        orig_setLocaleCC= (void *)SwizzleTyped(mgr, sel_registerName("setLocaleCountryCode:"),     (IMP)hook_setLocaleCC, ENC_SET1);
        SwizzleTyped(mgr, sel_registerName("getRestrictedCountryCodeFromTimezone"), (IMP)hook_str0, ENC_GET0);
        SwizzleTyped(mgr, sel_registerName("getLocaleFromTimezone"),                (IMP)hook_str0, ENC_GET0);
        SwizzleTyped(mgr, sel_registerName("getLocaleFromUserDefaults"),            (IMP)hook_str0, ENC_GET0);
    }

    if (mgru) {
        orig_setDevCC = (void *)SwizzleTyped(mgru, sel_registerName("setDeviceCountryCode:"), (IMP)hook_setDevCC, "C24@0:8@16");
        SwizzleTyped(mgru, sel_registerName("getCountryCodeFromUserDefaults"), (IMP)hook_str0, ENC_GET0);
        SwizzleTyped(mgru, sel_registerName("getDeviceCountryCode"),           (IMP)hook_str0, ENC_GET0);
        SwizzleTyped(mgru, sel_registerName("getCompanionCountryCode"),        (IMP)hook_str0, ENC_GET0);
        SwizzleTyped(mgru, sel_registerName("getPeerCountryCode"),             (IMP)hook_str0, ENC_GET0);
        SwizzleTyped(mgru, sel_registerName("getRemoteClientCountryCode"),     (IMP)hook_str0, ENC_GET0);
    }

    WriteMarker("hooks_installed");
    os_log(glog, "countryus hook installed (subsys=%p ctx=%p mgr=%p mgru=%p)",
           (void *)subsys, (void *)ctx, (void *)mgr, (void *)mgru);
}
