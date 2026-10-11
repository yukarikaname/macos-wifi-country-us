#!/bin/zsh
# netheal -- auto-repair configd's global network state.
#
# The symptom it exists for: after a Wi-Fi network change, configd can leave
# State:/Network/Global/IPv4 missing even though the Wi-Fi service still has a
# valid IPv4 configuration (address, routes, ARP-resolved gateway). No primary
# interface is selected, `scutil --nwi` says Not Reachable and the DNS
# resolvers go Not Reachable -- so the machine looks connected, keeps its
# address and its gateway answers ping, and cannot reach the internet or
# resolve a name. Restarting configd rebuilds the global state in ~20s.
#
# Why a watchdog and not a root cause: the trigger is a network change, which
# is not something this project can intercept, and configd recovers cleanly
# when nudged. This job only ever acts on the broken signature, never on a
# healthy machine.
#
# Guards, so it can never fight the boot job or run before the stack settles:
#   - skipped in the first two minutes after boot (countryinj owns that window)
#   - skipped whenever countryinj.sh is running
#   - skipped unless the Wi-Fi interface actually has an address (a machine
#     with Wi-Fi genuinely off must not be nudged)
#   - rate-limited to one restart per three minutes
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOG=/usr/local/var/log/netheal.log
STAMP=/usr/local/var/netheal.last

NOW=$(date +%s)
BOOT=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/')
[[ -n $BOOT && $((NOW - BOOT)) -lt 120 ]] && exit 0

# countryinj is mid-reinject: it has its own health check, stay out of the way
/usr/bin/pgrep -f countryinj.sh >/dev/null 2>&1 && exit 0

IF=$(networksetup -listallhardwareports 2>/dev/null |
  awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
IF=${IF:-en1}

# link genuinely up?
ADDR=$(ifconfig "$IF" 2>/dev/null | awk '/inet /{print $2; exit}')
[[ -z $ADDR ]] && exit 0

g4() {
  printf 'show State:/Network/Global/IPv4\n' |
    scutil 2>/dev/null | grep -c PrimaryInterface
}

# healthy -> do nothing at all
[[ $(g4) -ne 0 ]] && exit 0

if [[ -f $STAMP ]]; then
  LAST=$(cat "$STAMP" 2>/dev/null)
  [[ -n $LAST && $((NOW - LAST)) -lt 180 ]] && exit 0
fi
echo "$NOW" > "$STAMP" 2>/dev/null

{
  echo "$(date '+%F %T') link up on $IF ($ADDR) but no State:/Network/Global/IPv4 -- restarting configd"
  killall configd
  for i in {1..12}; do
    sleep 5
    [[ $(g4) -ne 0 ]] && break
  done
  echo "$(date '+%F %T') after restart: primary=$(printf 'show State:/Network/Global/IPv4\n' | scutil 2>/dev/null | awk -F' : ' '/PrimaryInterface/{print $2}') nwi=$(scutil --nwi 2>/dev/null | grep -m1 REACH | sed 's/.*(\(.*\)).*/\1/')"
} >> "$LOG" 2>&1

if [[ -f "$LOG" && $(stat -f %z "$LOG" 2>/dev/null) -gt 65536 ]]; then
  tail -c 32768 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
