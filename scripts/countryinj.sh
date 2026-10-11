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

  p=$(/usr/bin/pgrep -x "$short" | /usr/bin/head -1)
  pl_path=$(SP /bin/launchctl print "system/${lbl}" | /usr/bin/grep -m1 'path =' | /usr/bin/tr -d '\t')
  env=$(SP /bin/ps eww -o command= -p "$p" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -c DYLD_INSERT)
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
echo "$(TS) === reinject end ==="
