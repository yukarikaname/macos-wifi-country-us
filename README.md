# macos-wifi-country-us

[English](README.md) | [简体中文](README_CN.md)

Make macOS report the Wi-Fi regulatory country as **US** instead of **CN** —
a dyld injection that survives reboot. Tested on macOS 27.0.1 (Apple silicon).

> [!IMPORTANT]
> **Requires SIP disabled** (`csrutil status` → `disabled`). While SIP is on,
> dyld strips `DYLD_*` variables from system processes, which is the whole
> mechanism this relies on. `install.sh` checks this and refuses to run.

## Install

```sh
git clone https://github.com/yukarikaname/macos-wifi-country-us.git
cd macos-wifi-country-us
./install.sh
```

It preflights macOS, the Xcode Command Line Tools, SIP and sudo — aborting
before it changes anything if one fails — then builds both dylibs, installs the
launchd overrides and the `/usr/local/bin` wrappers, restarts
`airportd`/`countryd` (Wi-Fi drops for a few seconds; a watchdog reverts to the
system config if it does not come back) and finishes with a verification pass.

```sh
./install.sh --dry-run      # run every check, change nothing
./install.sh --uninstall    # remove everything this project installed
```

## Verify

```sh
./scripts/verify.sh

/usr/local/bin/system_profiler SPAirPortDataType | grep -E 'Locale|Country Code'
```

`verify.sh` prints `PASS`/`FAIL` per check and exits non-zero on any failure.
Expected from `system_profiler`: `Locale: USA`, `Country Code: US`.

| Surface | Before | After |
|---|---|---|
| `system_profiler` | `Locale: Unknown`, `Country Code: CN` | `Locale: USA`, `Country Code: US` |
| CoreWLAN `CWInterface.countryCode` | `(nil)` | `US` |
| `ioreg` (wrapped) | `IO80211CountryCode = "CN"` | `"US"` |
| airportd internal state | `CN` | `US` |
| Driver value (`/usr/sbin/ioreg`) | `CN` | unchanged — not writable from userspace |
| SSH / Wi-Fi across reboot | — | intact |

## Uninstall

```sh
./install.sh --uninstall
```

## How it works

macOS derives the country code from a majority vote over country IEs in nearby
AP beacons. The value is **not writable from userspace** (IORegistry writes are
accepted and ignored), so the only lever is the reading side:

- **`libcountryus.dylib`** → `airportd` + `countryd`, injected per-job through
  `DYLD_INSERT_LIBRARIES` in `/Library/LaunchDaemons` override plists (the
  `/System` originals are sealed read-only).
- **`libcountryus_reader.dylib`** → the tools that actually display it —
  `system_profiler`, `ioreg`, CoreWLAN clients — injected through PATH shims in
  `/usr/local/bin`, hooking the reporter's model getters, `CWInterface`, and
  ioreg's property reads.
- **`com.local.countryinj`** → boot LaunchDaemon. At boot launchd prefers the
  `/System` plist over a duplicate `/Library` label, so without this job the
  override is silently dropped and the machine reverts to CN. It re-applies
  both overrides 45 s after boot, watchdogged so it can never leave you
  without Wi-Fi. It then restarts `WiFiAgent` and `ControlCenter` (both
  cache Wi-Fi state from *before* the restart) and checks that configd still
  owns `State:/Network/Global/IPv4`, renewing the DHCP lease if not.

One hard rule: **never** `launchctl setenv DYLD_INSERT_LIBRARIES`. It reaches
every job including hardened-runtime `sshd-keygen-wrapper`, and AMFI SIGKILLs
it at load time — that takes SSH down. All env vars here stay scoped per-job or
per-command.

Reverse-engineering details, crash forensics and porting gotchas:
[NOTES.md](NOTES.md).

## FAQ

**Does it survive re-enabling SIP?**
No — but nothing breaks either. With SIP on, dyld discards `DYLD_*` before
starting system processes, so the injection silently stops and everything goes
back to CN. All files stay installed: disable SIP from Recovery again and
reboot, and it resumes with no reinstall. `verify.sh` flags this as its own
"SIP state" check. This follows Apple's documented behaviour and was not
measured on this machine (toggling SIP needs a Recovery reboot each way).

**The Wi-Fi menu's Hardware Address is blank when I Option-click it.**
Not this project's dylibs — but this project's restart of `airportd` is what
triggers it. ControlCenter snapshots its Wi-Fi details at login, i.e. *before*
the boot job restarts `airportd`, and never refreshes them. The boot job now
restarts it automatically, so a fresh login is already correct; if it ever
recurs mid-session, `killall ControlCenter` repopulates it in ~2 s.

**System Settings → Wi-Fi says "Not Configured" while the link works.**
Also a boot-time side effect, and the boot job now self-heals both halves:

1. *Stale UI agent.* `WiFiAgent` — the "WiFi user agent" Settings and
   ControlCenter both ask — also snapshots at login, and once its
   `CWWiFiAgent` is stale it keeps answering from the boot snapshot, including
   "power is OFF" while the interface is up and carrying traffic. Settings
   then displays "Not Configured". The boot job restarts `WiFiAgent` too.
2. *configd loses its global state.* Restarting `airportd` can make configd
   drop `State:/Network/Global/IPv4`: `scutil --nwi` says "Not Reachable" and
   DNS dies, while the address, the default route and the gateway all survive
   — so the machine looks connected and has no internet. The job waits for
   configd to build the state, restarts configd if it does not, and only then
   escalates: radio power cycle, then the system plists.

   To repair a broken machine by hand: `sudo killall configd`, then **wait one
   to two minutes** — it takes that long to repopulate.

   Do **not** "fix" it with `sudo ipconfig set en1 DHCP`. That fixes the
   symptom by taking the interface away from the Wi-Fi service, and the machine
   then looks healthy until the *next* network change, when configd has no
   service state left to reconfigure and DNS and the default route are lost
   again. If an interface-level config is already installed from an earlier
   repair, release it with `sudo ipconfig set en1 NONE` once configd is healthy
   again, and let the service own the interface.

**`wdutil info` shows `Country Code: (null)`.**
Pre-existing on the machine this was built on — the whole WIFI section is
null, with and without injection. Not caused by this project.

**It went back to CN after a reboot.**
Run `./scripts/verify.sh`. It reports the launchd override path, the global
`DYLD_INSERT_LIBRARIES` (must be empty) and whether the dylibs loaded;
`/usr/local/var/log/countryinj.log` has the boot job's transcript.

For network-health forensics, `scripts/netwatch.sh` — installed as the
optional `com.local.netwatch` job (bootstrap the plist yourself; the installer
does not touch it) — samples configd's global state, gateway/WAN/DNS
reachability and RSSI every 5 minutes into
`/usr/local/var/log/netwatch.log`. It is what pinned the "Not Configured"
episodes to the boot reinject's timeline.

## Repo layout

```
install.sh   one-shot installer (preflight: macOS, CLT, SIP, sudo)
src/         hook_countryus.m   daemon-side dylib (airportd, countryd)
             hook_reader.m      reader-side dylib (system_profiler, ioreg, CoreWLAN)
launchd/     override plists for airportd/countryd + com.local.countryinj
             + com.local.netwatch (optional diagnostic)
scripts/     build_*, install_*, restart_daemons, countryinj, verify,
             netwatch, uninstall
wrappers/    system_profiler, wdutil, ioreg
tools/       sshexec/push/pull, mkoverride, pldiff (password via MAC_SSH_PASS)
```
