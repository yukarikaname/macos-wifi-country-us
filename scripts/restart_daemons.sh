#!/bin/zsh
# Restart airportd and countryd so they pick up the /Library override plists
# (which carry the per-job DYLD_INSERT_LIBRARIES).
#
# Airportd is restarted detached, with a watchdog that reverts to the system
# plist if the dylib fails to load -- so a bad build can never leave the
# machine without Wi-Fi.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

OUT=/tmp/opencode
LOG=$OUT/restart.log
mkdir -p $OUT

sudo rm -f $OUT/SWIZZLE.txt $OUT/HOOK_LOADED

cat > $OUT/restart_job.sh <<'JEOF'
#!/bin/zsh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
L=/tmp/opencode/restart.log
echo "$(date '+%F %T') start" > $L

for lbl in com.apple.airportd com.apple.countryd; do
  short=${lbl##*.}
  sudo launchctl bootout "system/$lbl" >> $L 2>&1
  sleep 3
  sudo launchctl bootstrap system "/Library/LaunchDaemons/$lbl.plist" >> $L 2>&1
  echo "$(date '+%F %T') $lbl bootstrap rc=$?" >> $L
  sleep 8

  P=$(pgrep -x $short | head -1)
  E=0
  [ -n "$P" ] && sudo ps eww -o command= -p $P 2>/dev/null | tr ' ' '\n' | grep -q DYLD_INSERT && E=1
  echo "$(date '+%F %T') $short pid=$P env=$E" >> $L

  # Watchdog: only the Wi-Fi-carrying daemon can strand the machine.  Fall
  # back to the system plist if injection did not take.
  if [ "$short" = "airportd" ] && { [ -z "$P" ] || [ "$E" != "1" ]; }; then
    echo "$(date '+%F %T') WATCHDOG revert $lbl" >> $L
    sudo launchctl bootout "system/$lbl" >> $L 2>&1
    sleep 3
    sudo launchctl bootstrap system "/System/Library/LaunchDaemons/$lbl.plist" >> $L 2>&1
  fi
done
echo "$(date '+%F %T') end" >> $L
JEOF

chmod +x $OUT/restart_job.sh

# --wait runs in the foreground so a caller (install.sh) can verify immediately
# afterwards.  Without it, run detached: restarting airportd drops Wi-Fi for a
# few seconds, and a foreground run under launchd/ssh would be killed with it.
if [[ "$1" == "--wait" ]]; then
  "$OUT/restart_job.sh"
  echo "restart finished; log at $LOG"
else
  nohup $OUT/restart_job.sh >/dev/null 2>&1 &
  echo "restart scheduled; tail $LOG in ~30s"
fi
