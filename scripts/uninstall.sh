#!/bin/zsh
# Remove everything this project installs.  Returns the machine to stock:
# system plists only, no wrappers, no dylibs, no reinjector.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "=== unload reinjector ==="
sudo launchctl bootout system/com.local.countryinj 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.local.countryinj.plist
sudo rm -f /usr/local/bin/countryinj.sh

echo "=== restore stock daemons ==="
for lbl in com.apple.airportd com.apple.countryd; do
  sudo launchctl bootout "system/$lbl" 2>/dev/null
  sleep 2
  sudo rm -f "/Library/LaunchDaemons/$lbl.plist"
  sudo launchctl bootstrap system "/System/Library/LaunchDaemons/$lbl.plist" 2>/dev/null
  echo "  $lbl back on /System plist"
done

echo "=== remove reader wrappers ==="
for n in system_profiler wdutil ioreg; do
  sudo rm -f "/usr/local/bin/$n"
done

echo "=== remove dylibs ==="
sudo rm -f /usr/local/lib/libcountryus.dylib /usr/local/lib/libcountryus_reader.dylib

echo
echo "done -- verify with: /usr/sbin/system_profiler SPAirPortDataType | grep 'Country Code'"
