#!/bin/zsh
# Post-reboot verification for the "US country code" work.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
S(){ if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi }
exec > /tmp/opencode/BOOTVERIFY.txt 2>&1

echo "=== boot time / uptime ==="
uptime
echo

echo "=== 1. launchd picked the /Library overrides for BOTH jobs ==="
S launchctl print system/com.apple.airportd  2>/dev/null | grep -E "^\s*path|DYLD_INSERT" | head -3
S launchctl print system/com.apple.countryd 2>/dev/null | grep -E "^\s*path|DYLD_INSERT" | head -3
echo

echo "=== 2. global env must be EMPTY (sshd safety) ==="
echo "DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"
echo

echo "=== 3. daemons up, dylib loaded ==="
echo "airportd pid=$(pgrep -x airportd | head -1)  countryd pid=$(pgrep -x countryd | head -1)"
echo "--- HOOK_LOADED ---"
cat /tmp/opencode/HOOK_LOADED 2>&1 | head -10
echo "--- SWIZZLE.txt OK count ---"
grep -cE "^OK" /tmp/opencode/SWIZZLE.txt 2>/dev/null
echo "--- any failures? ---"
grep -E "FAIL|SKIP" /tmp/opencode/SWIZZLE.txt 2>/dev/null | head -5
echo

echo "=== 4. airportd internal country ==="
S log show --last 10m --predicate 'process == "airportd"' 2>/dev/null \
  | grep -E "countryCode US|_rdCountryCode|NetworkCountryCodeApplied" | tail -3
echo

echo "=== 5. reader surfaces (persistent wrappers) ==="
echo "--- system_profiler ---"
/usr/local/bin/system_profiler SPAirPortDataType 2>/dev/null | grep -E "Locale|Country Code" | head -4
echo "US=$(/usr/local/bin/system_profiler SPAirPortDataType 2>/dev/null | grep -c 'Country Code: US')  CN=$(/usr/local/bin/system_profiler SPAirPortDataType 2>/dev/null | grep -c 'Country Code: CN')"
echo "--- CoreWLAN (fresh, injected) ---"
[ -x /tmp/opencode/cw ] && env DYLD_INSERT_LIBRARIES=/usr/local/lib/libcountryus_reader.dylib /tmp/opencode/cw
echo

echo "=== 6. reader pieces present ==="
S ls -la /usr/local/lib/libcountryus.dylib /usr/local/lib/libcountryus_reader.dylib 2>&1
S ls -la /usr/local/bin/system_profiler /usr/local/bin/wdutil /usr/local/bin/ioreg 2>&1
echo

echo "=== 7. driver value (expected CN -- readers rewrite it) ==="
/usr/sbin/ioreg -l -w0 2>/dev/null | grep -E "IO80211CountryCode" | head -2
echo

echo "=== 8. WiFi up? ==="
/usr/local/bin/ioreg -l -w0 2>/dev/null | grep -c "IO80211InterfaceRole"
echo "=== DONE ==="
