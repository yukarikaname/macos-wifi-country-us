# wifi-country-us

Make macOS report Wi-Fi regulatory country **US** instead of **CN** on a single
machine, via dyld injection, surviving reboot.

Written and tested against macOS 27.0.1 (build 26A434), arm64e, on Apple
silicon. **SIP must be disabled** — nothing here works otherwise.

---

## Why the country code is CN

The driver publishes `IO80211CountryCode` on the Wi-Fi IORegistry node, and
derives it from the **country IEs in nearby AP beacons** — a majority vote over
scan results. It is not a stored preference. On the target machine that tally
came out `CN, count 8` vs `US, count 4`, so the driver said `CN`, and every
reader that asks the driver repeats `CN`.

That matters because the value is **not writable from userspace**:

- `IORegistryEntrySetCFProperty` on the DriverKit node returns `KERN_SUCCESS`
  and changes nothing — the write is accepted and ignored.
- `airportd` cannot push a country to the driver either. Instrumenting every
  setter (`setCountryCode:source:`, `retrySetCountryCode:source:`,
  `setLocaleCountryCode:`, `setDeviceCountryCode:`, `updRD`) with logging
  swizzles showed **zero calls at runtime**. There is no airportd→driver push
  path to hijack. `RDUpdateCountryCodeFromWiFiAPs` (exported by
  `RegulatoryDomain.framework`) is the *opposite* direction: airportd feeding
  AP beacon countries into countryd's estimate.

So the only lever is **reader-side**: intercept the processes that *display*
the country code and hand them US instead of CN. That is what this project does.

## Two dylibs, two injection points

### 1. `libcountryus.dylib` — daemon side

Source: [`src/hook_countryus.m`](src/hook_countryus.m)

Injected into **`airportd`** and **`countryd`**. Holds their internal state at
US (`countryCode`, `_rdCountryCode`, `NetworkCountryCodeAdvertised` /
`Applied`, countryd's cached estimates). The dylib gates itself on the
basename of the host process, so it is inert anywhere else.

### 2. `libcountryus_reader.dylib` — reader side

Source: [`src/hook_reader.m`](src/hook_reader.m)

Injected into the CLI tools that report the country. Three independent
interception points, because the readers do not all agree on where the value
comes from:

| Reader | Path taken | Hooked by |
|---|---|---|
| `system_profiler` | `SPAirPortReporter` plugin's own model object | `-[SPAirPortInterface countryCode]` / `-[SPAirPortNetwork countryCode]` getter swizzles |
| CoreWLAN clients | `-[CWInterface countryCodeInternal]` | method swizzle (returns `(nil)` without location authorization, so the value is forced unconditionally) |
| `ioreg` | `IORegistryEntryCreateCFProperty` / `SearchCFProperty` / `CreateCFProperties` | `__DATA,__interpose` — rewrites `IO80211CountryCode` in returned dicts |

Also forces the plugin's `locale` property to `USA` so the report reads
`Locale: USA` instead of `Locale: Unknown`.

### What is *not* hooked, and why

`Apple80211CopyValue` — the IO80211 user-client call that
`SPAirPortReporter` imports — is interposed for **logging only**. Its
prototype is published in no header on disk, so it was recovered from the call
sites in the plugin:

```
bl   _Apple80211CopyValue
cbnz w0, ...            ; returns kern_return_t in w0
ldr  x20, [sp, #0x80]   ; out value from the 4th arg slot
```

i.e. `kern_return_t Apple80211CopyValue(a11Ref, key, options, CFTypeRef *out)`
with the out-pointer in **x3**, not x2. Guessing wrong here is what produced the
two crash modes documented under [Gotchas](#gotchas) — declaring it three-arg
put the out-pointer in x2 (always NULL from the caller), and resolving the
original via `dlsym` recursed until the thread hit the stack guard page. The
value is not read from this call anyway (the country arrives via the plugin's
model object), so the interpose stays log-only.

---

## Persistence — and the trap that makes it necessary

### Reader side: PATH wrappers

`system_profiler`, `wdutil` and `ioreg` are user-invoked CLI tools, not launchd
jobs, so per-job plist injection does not apply. They get thin wrappers in
`/usr/local/bin`, which precedes `/usr/bin` in a login shell's PATH:

```sh
#!/bin/sh
export DYLD_INSERT_LIBRARIES=/usr/local/lib/libcountryus_reader.dylib
exec /usr/sbin/system_profiler "$@"
```

Files on disk survive reboot by definition. Anything calling the real path
(`/usr/sbin/system_profiler`) is unaffected.

### Daemon side: per-job env in `/Library` override plists

`/Library/LaunchDaemons/com.apple.{airportd,countryd}.plist` are clones of the
`/System` originals with exactly one added key:

```xml
<key>EnvironmentVariables</key>
<dict><key>DYLD_INSERT_LIBRARIES</key><string>/usr/local/lib/libcountryus.dylib</string></dict>
```

The `/System` volume is APFS-sealed and read-only, so the originals cannot be
edited. `tools/pldiff.py` confirms the clones differ from the originals in
precisely that one key.

### The trap: launchd prefers `/System` at boot

An explicit `launchctl bootout` + `bootstrap system /Library/...` makes launchd
pick the `/Library` override. **A normal boot does not** — launchd resolves the
duplicate label in favour of `/System`, so the dylib silently stops loading and
the machine reverts to reporting CN.

`com.local.countryinj` ([`scripts/countryinj.sh`](scripts/countryinj.sh)) closes
that gap: a boot-time LaunchDaemon that waits 45s for the stack to settle, then
re-applies both overrides with the bootout+bootstrap sequence that is known to
work. It carries a watchdog that reverts airportd to the system plist if Wi-Fi
does not come back, so it cannot strand the machine without network. It logs to
`/usr/local/var/log/countryinj.log`.

---

## ⚠️ Do not use a global `DYLD_INSERT_LIBRARIES`

`launchctl setenv DYLD_INSERT_LIBRARIES=...` was tried and **took down SSH on
the target machine**. The variable propagates through launchd to every job,
including `sshd-keygen-wrapper`, which is hardened-runtime. AMFI rejects the
unsigned-into-a-hardened-process load and SIGKILLs it at dyld load time —
before any code in the dylib runs, so a process-name gate in the constructor
cannot protect anything.

Everything in this project keeps the env var scoped: per-job in launchd
plists, per-command in wrapper scripts. **Do not reintroduce a machine-wide
`setenv`.**

---

## Install

```sh
# 1. daemon-side dylib
./scripts/build_countryus.sh

# 2. reader-side dylib
./scripts/build_reader.sh

# 3. launchd override plists + boot reinjector
./scripts/install_launchd.sh

# 4. reader PATH wrappers
./scripts/install_wrappers.sh

# 5. restart the daemons to pick up the overrides
./scripts/restart_daemons.sh
```

Check it:

```sh
./scripts/verify.sh
```

## Verify manually

```sh
/usr/local/bin/system_profiler SPAirPortDataType | grep -E 'Locale|Country Code'
/usr/local/bin/ioreg -l -w0 | grep IO80211CountryCode
/usr/sbin/ioreg -l -w0 | grep IO80211CountryCode     # unwrapped: shows driver's real value
```

Expected: the wrapped readers report `US`; the unwrapped `/usr/sbin/ioreg`
shows the driver's beacon-derived value, which is `CN` unless the local RF
happened to tally US.

Diagnosis markers (note `/tmp` is wiped on every macOS boot, so these
regenerate after each one):

- `/tmp/opencode/HOOK_LOADED` — one line per process that loaded a dylib
- `/tmp/opencode/SWIZZLE.txt` — `OK` per swizzle installed
- `/usr/local/var/log/countryinj.log` — the boot reinjector's transcript

## Uninstall

```sh
./scripts/uninstall.sh
```

Removes the wrappers, both dylibs, the override plists and the reinjector, and
returns airportd/countryd to their `/System` plists.

---

## Results

| Surface | Before | After |
|---|---|---|
| `system_profiler SPAirPortDataType` | `Locale: Unknown`, `Country Code: CN` | `Locale: USA`, `Country Code: US` (all network lines) |
| CoreWLAN `CWInterface.countryCode` | `(nil)` | `US` |
| `ioreg` (wrapped) | `IO80211CountryCode = "CN"` | `"US"` |
| Driver value (unwrapped `ioreg`) | `CN` | `CN` — unchanged, and not writable |
| airportd internal state | `CN` | `US` |
| SSH / Wi-Fi across reboot | — | intact |

`wdutil info` reports `Country Code: (null)` in **both** states. That is
pre-existing on this machine (its whole WIFI section is null), proved by an
A/B run with and without injection, and is not caused by this project.

## Gotchas encountered

Worth knowing if you port this to another macOS release:

- **`otool` needs `-arch arm64e`** — these binaries are arm64e, not arm64, and
  `otool -arch arm64` reports "does not contain architecture" while appearing
  to succeed. `llvm-objdump` is not installed; `/usr/bin/objdump` is.
- **Private frameworks may be stubs.** `IO80211.framework` on disk has no
  binary — its code lives in the dyld shared cache, so `nm -gU` reports zero
  exports. `dyld_info -exports` works, and the SDK `.tbd` satisfies the link
  via `-F "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks"
  -framework IO80211`.
- **zsh ties `path` to `PATH`.** Assigning `path=$(...)` in a zsh script
  clobbers `PATH`, which surfaces later as `command not found: grep`. Renamed
  to `pl_path` throughout. This one cost an entire failed boot-reinjection run.
- **`/usr/bin/test` does not exist on macOS** — use the shell builtin.
- **`/tmp` is wiped at boot** — anything you expect to persist across reboot
  belongs under `/usr/local` or `/var`, not `/tmp`.
- **`system_profiler` forks** — expect two PIDs per invocation, each running
  the injected constructor.
- **Arm64e pointers are PAC-signed.** Reading an interpose `orig` slot gives a
  signed value; casting and calling through it is fine, but `dlsym` on the same
  symbol can resolve back to your own replacement (see the recursion note
  above).
- **`CFGetTypeID` on a mis-declared return value** is how the wrong
  `Apple80211CopyValue` prototype was caught: a `kern_return_t` of `0` read as
  a `CFTypeRef` looks like a perfectly plausible null.
- **`plutil -insert -dict` is unsupported** — use Python's `plistlib`.
- **`log show` needs sudo** and its `--end` is ignored; filter on timestamps
  with `awk` instead.

## Layout

```
src/          hook_countryus.m   daemon-side dylib (airportd, countryd)
              hook_reader.m      reader-side dylib (system_profiler, CoreWLAN, ioreg)
launchd/      com.apple.airportd.plist     /Library override + dylib env
              com.apple.countryd.plist     /Library override + dylib env
              com.local.countryinj.plist   boot-time reinjector
scripts/      build_countryus.sh  build + install the daemon dylib
              build_reader.sh     build + install the reader dylib
              install_launchd.sh  install the override plists + reinjector
              install_wrappers.sh install the /usr/local/bin wrappers
              restart_daemons.sh  restart airportd/countryd (with watchdog)
              countryinj.sh       boot reinjector body
              verify.sh           state check
              uninstall.sh        remove everything
wrappers/     system_profiler, wdutil, ioreg
tools/        sshexec.py, push.py, pull.py   remote helpers (password from
                                             MAC_SSH_PASS env var, not baked in)
              mkoverride.py, pldiff.py       plist clone + drift check
```

## Unrelated note

`RegionSpoof.kext` was already present in `/Library/Extensions` on the target
machine and is inert. This project does not touch it.
