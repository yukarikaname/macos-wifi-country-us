#!/bin/zsh
# Install the launchd pieces:
#   1. /Library/LaunchDaemons/com.apple.{airportd,countryd}.plist
#        Per-job override plists, clones of the /System ones with a single
#        added EnvironmentVariables.DYLD_INSERT_LIBRARIES key.
#   2. /Library/LaunchDaemons/com.local.countryinj.plist
#        Boot-time re-applier.  See the README: launchd resolves duplicate
#        labels in favour of /System at boot, so the overrides above are
#        ignored on a normal boot and must be re-applied explicitly.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE=$(cd "$(dirname "$0")/.." && pwd)

echo "=== lint ==="
for p in "$HERE"/launchd/*.plist; do
  plutil -lint "$p"
done

echo
echo "=== install override plists ==="
for lbl in com.apple.airportd com.apple.countryd; do
  sudo cp "$HERE/launchd/$lbl.plist" /Library/LaunchDaemons/$lbl.plist
  sudo chown root:wheel /Library/LaunchDaemons/$lbl.plist
  sudo chmod 644 /Library/LaunchDaemons/$lbl.plist
  echo "  /Library/LaunchDaemons/$lbl.plist"
done

echo
echo "=== install boot reinjector ==="
sudo cp "$HERE/scripts/countryinj.sh" /usr/local/bin/countryinj.sh
sudo chmod 755 /usr/local/bin/countryinj.sh
sudo chown root:wheel /usr/local/bin/countryinj.sh
sudo mkdir -p /usr/local/var/log
sudo cp "$HERE/launchd/com.local.countryinj.plist" /Library/LaunchDaemons/com.local.countryinj.plist
sudo chown root:wheel /Library/LaunchDaemons/com.local.countryinj.plist
sudo chmod 644 /Library/LaunchDaemons/com.local.countryinj.plist

echo
echo "=== load reinjector for this boot ==="
sudo launchctl bootout system/com.local.countryinj 2>/dev/null
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.countryinj.plist 2>&1 | head -3
echo "(it sleeps ~45s, re-applies the overrides, then logs to /usr/local/var/log/countryinj.log)"
