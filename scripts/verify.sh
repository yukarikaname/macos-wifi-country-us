#!/bin/zsh
# Post-install / post-boot verification.
#
# Prints to stdout AND to /tmp/opencode/BOOTVERIFY.txt (the file survives only
# until the next reboot, like everything else under /tmp).  Exits non-zero if
# any check fails, so install.sh can gate on it.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
S(){ if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi }

/bin/mkdir -p /tmp/opencode
REPORT=/tmp/opencode/BOOTVERIFY.txt

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

exec > >(tee "$REPORT") 2>&1

echo "=== boot / uptime ==="
uptime
echo

echo "=== 0. SIP state -- this is the kill switch for the whole project ==="
# dyld purges DYLD_* environment variables when starting protected (built-in)
# executables while SIP is on, so the overrides and wrappers would still be
# installed and still be setting the variable, and it would still do nothing.
# Checking here means "I re-enabled SIP later" is caught by a plain verify run
# instead of being noticed as a mystery regression weeks later.
SIPST=$(/usr/bin/csrutil status 2>&1)
if print -r -- "$SIPST" | /usr/bin/grep -qi "disabled"; then
  pass "SIP disabled -- $SIPST"
else
  fail "SIP is on ($SIPST) -- dyld now strips DYLD_INSERT_LIBRARIES from system daemons, so everything here is installed but inert (silently back to CN).  Nothing is broken and nothing needs reinstalling: disable SIP from Recovery and reboot, and countryinj re-applies it."
fi
echo

echo "=== 1. global DYLD_INSERT_LIBRARIES must be EMPTY (sshd safety) ==="
G=$(launchctl getenv DYLD_INSERT_LIBRARIES)
if [[ -z "$G" ]]; then
  pass "global env empty"
else
  fail "global env is set to '$G' -- this SIGKILLs hardened-runtime sshd.  Remove it now: sudo launchctl unsetenv DYLD_INSERT_LIBRARIES"
fi
echo

echo "=== 2. daemons running ==="
AP=$(pgrep -x airportd | head -1)
CD=$(pgrep -x countryd | head -1)
if [[ -n "$AP" ]]; then pass "airportd pid=$AP"; else fail "airportd not running"; fi
if [[ -n "$CD" ]]; then pass "countryd pid=$CD"; else fail "countryd not running (may be on-demand; not fatal)"; fi
echo

echo "=== 3. launchd is using the /Library override plists ==="
for lbl in com.apple.airportd com.apple.countryd; do
  P=$(S launchctl print "system/$lbl" 2>/dev/null | grep -m1 'path =' | tr -d '\t')
  if print -r -- "$P" | grep -q '/Library/LaunchDaemons/'; then
    pass "$lbl -> $P"
  else
    fail "$lbl -> ${P:-no path found}.  At boot launchd prefers /System for duplicate labels; com.local.countryinj is supposed to re-apply it ~45s in.  Check /usr/local/var/log/countryinj.log"
  fi
done
echo

echo "=== 4. dylib actually loaded into the daemons ==="
if [[ -f /tmp/opencode/HOOK_LOADED ]]; then
  grep -q "proc=airportd loaded" /tmp/opencode/HOOK_LOADED \
    && pass "airportd loaded libcountryus.dylib" \
    || fail "airportd did not load the dylib"
  grep -q "proc=countryd loaded" /tmp/opencode/HOOK_LOADED \
    && pass "countryd loaded libcountryus.dylib" \
    || fail "countryd did not load the dylib"
else
  fail "/tmp/opencode/HOOK_LOADED missing (wiped at boot; regenerate by restarting the daemons)"
fi
echo

echo "=== 5. swizzles installed ==="
if [[ -f /tmp/opencode/SWIZZLE.txt ]]; then
  N=$(grep -cE "^OK" /tmp/opencode/SWIZZLE.txt 2>/dev/null)
  F=$(grep -cE "^FAIL" /tmp/opencode/SWIZZLE.txt 2>/dev/null)
  echo "  OK=$N FAIL=$F"
  [[ "$F" -eq 0 ]] && pass "no swizzle failures" || fail "$F swizzle(s) failed -- see /tmp/opencode/SWIZZLE.txt"
  grep -E "FAIL|SKIP" /tmp/opencode/SWIZZLE.txt 2>/dev/null | head -5
else
  fail "/tmp/opencode/SWIZZLE.txt missing (wiped at boot)"
fi
echo

echo "=== 6. installed pieces present ==="
for f in /usr/local/lib/libcountryus.dylib /usr/local/lib/libcountryus_reader.dylib \
         /usr/local/bin/system_profiler /usr/local/bin/wdutil /usr/local/bin/ioreg \
         /usr/local/bin/countryinj.sh /Library/LaunchDaemons/com.local.countryinj.plist; do
  [[ -e "$f" ]] && pass "$f" || fail "$f missing"
done
echo

echo "=== 7. reader surfaces report US (the actual goal) ==="
SP=$(/usr/local/bin/system_profiler SPAirPortDataType 2>/dev/null)
US=$(print -r -- "$SP" | grep -c 'Country Code: US')
CN=$(print -r -- "$SP" | grep -c 'Country Code: CN')
LOC=$(print -r -- "$SP" | grep -m1 'Locale:')
echo "  system_profiler: US=$US CN=$CN  $LOC"
[[ "$US" -gt 0 && "$CN" -eq 0 ]] && pass "system_profiler reports US only" \
  || fail "system_profiler still shows CN (US=$US CN=$CN) -- wrappers not on PATH, or reader dylib not loaded"

if [[ -x /tmp/opencode/cw ]]; then
  echo "  CoreWLAN:"
  env DYLD_INSERT_LIBRARIES=/usr/local/lib/libcountryus_reader.dylib /tmp/opencode/cw 2>&1 | sed 's/^/    /'
fi
echo

echo "=== 8. WiFi up ==="
N=$(/usr/sbin/ioreg -l -w0 2>/dev/null | grep -c "IO80211InterfaceRole")
echo "  interfaces=$N"
[[ "$N" -gt 0 ]] && pass "WiFi interfaces present" || fail "no WiFi interfaces -- WiFi is down"
echo

echo "=== 9. driver value (expected CN unless RF happens to tally US) ==="
/usr/sbin/ioreg -l -w0 2>/dev/null | grep -E "IO80211CountryCode" | head -2
echo "  (readers rewrite this at the reader side; the driver itself is not writable)"
echo

echo "=== report written to $REPORT ==="
if [[ $FAIL -eq 0 ]]; then
  echo "=== ALL CHECKS PASSED ==="
  exit 0
else
  echo "=== $FAIL CHECK(S) FAILED ==="
  exit 1
fi
