#!/bin/zsh
# Install the reader-side PATH wrappers into /usr/local/bin.
#
# Each wrapper exports DYLD_INSERT_LIBRARIES for the reader dylib and then
# execs the real binary.  /usr/local/bin precedes /usr/bin in a normal login
# shell's PATH, so `system_profiler`/`wdutil`/`ioreg` resolve to the wrappers
# while anything invoking the real path (/usr/sbin/system_profiler) is
# unaffected.
#
# This is deliberately NOT a global `launchctl setenv`: a machine-wide
# DYLD_INSERT_LIBRARIES gets inherited by hardened-runtime binaries such as
# sshd-keygen-wrapper, which AMFI then SIGKILLs at load time.  Per-job env on
# launchd jobs and per-command env in wrappers both stay scoped.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

DEST=/usr/local/bin
DYLIB=/usr/local/lib/libcountryus_reader.dylib

[ -f "$DYLIB" ] || { echo "missing $DYLIB -- run build_reader.sh first"; exit 1; }

sudo mkdir -p $DEST
for t in system_profiler:/usr/sbin/system_profiler wdutil:/usr/bin/wdutil ioreg:/usr/sbin/ioreg; do
  name=${t%%:*}; real=${t##*:}
  cat > /tmp/opencode/wrap_$name <<WEOF
#!/bin/sh
# Inject the country-code reader hook, then hand off to the real binary.
export DYLD_INSERT_LIBRARIES=$DYLIB
exec $real "\$@"
WEOF
  sudo cp /tmp/opencode/wrap_$name $DEST/$name
  sudo chmod 755 $DEST/$name
  echo "installed $DEST/$name -> $real"
done

echo
echo "--- verify resolution order (login shell) ---"
zsh -l -c 'which -p system_profiler; which -p wdutil; which -p ioreg' 2>/dev/null
