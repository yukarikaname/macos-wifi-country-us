#!/bin/zsh
# Build + install the daemon-side dylib (libcountryus.dylib).
#
# Injected into airportd and countryd via per-job EnvironmentVariables in
# /Library/LaunchDaemons.  Gates itself to those processes by name, so the
# dylib is inert if it ever lands anywhere else.
#
# Usage: ./build_countryus.sh [source-dir]   (defaults to ../src)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

SRC=${1:-$(cd "$(dirname "$0")/../src" && pwd)}
OUT=/tmp/opencode
STAGE=$OUT/libcountryus.dylib
DEST=/usr/local/lib/libcountryus.dylib

mkdir -p $OUT

echo "=== build ($SRC/hook_countryus.m) ==="
rm -f $STAGE
clang -arch arm64e -dynamiclib -fno-objc-arc \
  -o $STAGE "$SRC/hook_countryus.m" \
  -framework Foundation -lobjc 2>&1 | head -30
[ -f $STAGE ] || { echo "BUILD FAILED"; exit 1; }
codesign -s - -f $STAGE 2>&1 | head -2
file $STAGE | sed 's/.*: //'

echo
echo "=== install ==="
sudo cp $STAGE $DEST
sudo chown root:wheel $DEST
sudo chmod 755 $DEST
sudo codesign -s - -f $DEST 2>&1 | head -2
ls -la $DEST

echo
echo "Installed.  Restart the daemons with scripts/restart_daemons.sh to pick it up."
