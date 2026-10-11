#!/bin/zsh
# Build + install the reader-side dylib (libcountryus_reader.dylib).
#
# Injected into CLI readers (system_profiler, wdutil, ioreg) through the
# wrappers in /usr/local/bin.  Rewrites the country code at the points where
# those tools read it: SPAirPortReporter's own model object, CWInterface, and
# the IORegistry property lookups.
#
# Usage: ./build_reader.sh [source-dir]   (defaults to ../src)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

SRC=${1:-$(cd "$(dirname "$0")/../src" && pwd)}
OUT=/tmp/opencode
STAGE=$OUT/hook_reader.dylib
DEST=/usr/local/lib/libcountryus_reader.dylib

SDKROOT=$(xcrun --show-sdk-path 2>/dev/null)
echo "sdk=$SDKROOT"
mkdir -p $OUT

echo
echo "=== build ($SRC/hook_reader.m) ==="
rm -f $STAGE
clang -arch arm64e -dynamiclib -fno-objc-arc -o $STAGE "$SRC/hook_reader.m" \
  -framework Foundation -framework IOKit -framework CoreFoundation \
  -F "$SDKROOT/System/Library/PrivateFrameworks" -framework IO80211 \
  -lobjc 2>&1 | head -30
[ -f $STAGE ] || { echo "BUILD FAILED"; exit 1; }
codesign -s - -f $STAGE 2>&1 | head -1
file $STAGE | sed 's/.*: //'

echo
echo "=== install ==="
sudo cp $STAGE $DEST
sudo chown root:wheel $DEST
sudo chmod 755 $DEST
sudo codesign -s - -f $DEST 2>&1 | head -2
ls -la $DEST
