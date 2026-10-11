#!/bin/zsh
# Boot-time reinjector -- ALL paths absolute, no reliance on PATH.
#
# launchd resolves duplicate-label jobs in favour of /System at boot, so the
# /Library/LaunchDaemons/{airportd,countryd}.plist overrides -- which DO win an
# explicit bootout+bootstrap -- are ignored during a normal boot.  This job runs
# once at boot, waits for the stack to settle, then re-applies each override
# with an explicit bootout+bootstrap, the sequence proven to make launchd pick
# the /Library copy.
#
# Absolute paths are mandatory.  The first version of this script used bare
# command names plus `export PATH=...` and still hit `command not found: grep`
# under launchd -- the real cause was that it assigned to `path`, which zsh
# ties to PATH, clobbering it mid-loop.  That made the watchdog's test fail
# open and revert to the system plists.  No reliance on PATH now, and the
# variable that used to be `path` is called `pl_path`.
/bin/mkdir -p /usr/local/var/log /tmp/opencode
# This runs as root, and /tmp is sticky-bit: a root-owned 755 /tmp/opencode
# would then be unwritable by the normal user and impossible to delete, which
# blocks tools/push.py on the next boot.  Make it world-writable + sticky so
# both root and the user can write.
/bin/chmod 1777 /tmp/opencode
LOG=/usr/local/var/log/countryinj.log
exec >> "$LOG" 2>&1

TS() { /bin/date '+%F %T'; }
# Runs as root under launchd; when invoked by hand, escalate if needed.
SP() { if [[ $EUID -eq 0 ]]; then "$@"; else /usr/bin/sudo "$@"; fi }

echo "$(TS) === reinject start (pid $$) ==="

# WiFi must be up before touching airportd.
/bin/sleep 45

for lbl in com.apple.airportd com.apple.countryd; do
  ov="/Library/LaunchDaemons/${lbl}.plist"
  [[ -f "$ov" ]] || { echo "$(TS) SKIP no override for $lbl"; continue; }
  short=${lbl##*.}

  echo "$(TS) re-applying $lbl from $ov"
  SP /bin/launchctl bootout "system/${lbl}"
  /bin/sleep 2
  SP /bin/launchctl bootstrap system "$ov"
  /bin/sleep 1

  p=""
  # bootstrap returns before the daemon is actually up; poll instead of
  # grabbing an empty pid and feeding it to ps (which logs "Invalid
  # (zero-length) process id").
  for i in {1..15}; do
    p=$(/usr/bin/pgrep -x "$short" | /usr/bin/head -1)
    [[ -n "$p" ]] && break
    /bin/sleep 1
  done
  pl_path=$(SP /bin/launchctl print "system/${lbl}" | /usr/bin/grep -m1 'path =' | /usr/bin/tr -d '\t')
  if [[ -n "$p" ]]; then
    env=$(SP /bin/ps eww -o command= -p "$p" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -c DYLD_INSERT)
  else
    env="?"
  fi
  echo "$(TS) $lbl pid=$p $pl_path env_dyld=$env"
done

# Watchdog: if WiFi did not come back, fall back to the system plists so the
# machine is never left without network.  Test uses absolute /usr/bin/grep.
/bin/sleep 20
if ! /usr/sbin/ioreg -l -w0 2>/dev/null | /usr/bin/grep -q "IO80211InterfaceRole"; then
  echo "$(TS) WATCHDOG: WiFi down, reverting to system plists"
  for lbl in com.apple.airportd com.apple.countryd; do
    SP /bin/launchctl bootout "system/${lbl}"
    /bin/sleep 2
    SP /bin/launchctl bootstrap system "/System/Library/LaunchDaemons/${lbl}.plist"
  done
else
  echo "$(TS) WATCHDOG: WiFi up, keeping injected state"
fi

# Health check.  Restarting airportd outside the boot sequence reliably
# destroys configd's global network state: State:/Network/Global/IPv4
# vanishes, `scutil --nwi` reports Not Reachable and the DNS resolvers go
# Not Reachable -- while the interface keeps its address, the default route
# stays installed and the gateway still answers ping.  The machine therefore
# looks connected and cannot reach the internet or resolve a name, which is
# exactly what "Not Configured" in Settings accompanies.  At boot configd
# usually rebuilds this on its own within a few minutes, but not always, so
# check every time.  A DHCP renew is enough to make IPMonitor recreate the
# state, and unlike a radio power cycle it does not drop the link, so an SSH
# session riding on this interface survives the repair.
g4_present() {
  /usr/bin/printf 'show State:/Network/Global/IPv4\n' |
    /usr/sbin/scutil 2>/dev/null | /usr/bin/grep -c PrimaryInterface
}
# en1 is Wi-Fi on the machine this was written for, but resolve it properly so
# the repair targets the radio and not, say, an Ethernet port on another Mac.
wifi_dev=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null |
  /usr/bin/awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
wifi_dev=${wifi_dev:-en1}
if [[ $(g4_present) -eq 0 ]]; then
  echo "$(TS) HEALTH: configd lost State:/Network/Global/IPv4 -- renewing DHCP on $wifi_dev"
  SP /usr/sbin/ipconfig set "$wifi_dev" DHCP
  /bin/sleep 12
fi
if [[ $(g4_present) -eq 0 ]]; then
  echo "$(TS) HEALTH: still missing -- power-cycling the radio"
  SP /usr/sbin/networksetup -setairportpower "$wifi_dev" off
  /bin/sleep 4
  SP /usr/sbin/networksetup -setairportpower "$wifi_dev" on
  /bin/sleep 25
fi
if [[ $(g4_present) -eq 0 ]]; then
  echo "$(TS) HEALTH: state still missing -- falling back to the watchdog revert"
  for lbl in com.apple.airportd com.apple.countryd; do
    SP /bin/launchctl bootout "system/${lbl}"
    /bin/sleep 2
    SP /bin/launchctl bootstrap system "/System/Library/LaunchDaemons/${lbl}.plist"
  done
  /bin/sleep 20
  if [[ $(g4_present) -eq 0 ]]; then
    SP /usr/sbin/ipconfig set "$wifi_dev" DHCP
    /bin/sleep 12
  fi
  echo "$(TS) HEALTH: reverted to system plists, global state now $(g4_present)"
else
  echo "$(TS) HEALTH: global state ok (PrimaryInterface present)"
fi

# UI resync.  WiFiAgent -- the "WiFi user agent" the settings extension and
# ControlCenter both ask -- and ControlCenter itself both start at login, i.e.
# BEFORE this job restarts airportd, and neither re-syncs against the new
# daemon.  WiFiAgent keeps answering from its boot-time snapshot, including
# "Scan not allowed, power is OFF" while the link is up and carrying traffic,
# so System Settings shows "Not Configured" for a perfectly healthy connection.
# ControlCenter caches the same way and shows "not connected" plus an empty
# Hardware Address in the menu bar.  This is the same class of bug as
# ControlCenter holding pre-restart Wi-Fi details in general.  Restarting them
# is invisible for WiFiAgent and ~2s of menu-bar rebuild for ControlCenter --
# at boot+1min that is a fair trade for UI that tells the truth.  Restarted in
# that order, so ControlCenter re-reads from an already-resynced WiFiAgent.
for ui_app in WiFiAgent ControlCenter; do
  if /usr/bin/pgrep -x "$ui_app" >/dev/null 2>&1; then
    if SP /usr/bin/killall "$ui_app" 2>/dev/null; then
      echo "$(TS) restarted $ui_app so it re-reads airportd state"
    else
      echo "$(TS) $ui_app not restarted (killall failed)"
    fi
  fi
done
echo "$(TS) === reinject end ==="
