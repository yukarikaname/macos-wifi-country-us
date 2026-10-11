#!/bin/zsh
# netwatch -- 5-minute network health sampler.
#
# Installed as com.local.netwatch.  It exists to settle causation questions:
# every sample records configd's global state (nwi reachability, primary
# interface), gateway/WAN/DNS reachability, RSSI and the last line of
# countryinj.log on one timestamped line, so an incident can be correlated
# against the boot reinjector's timeline.  The log self-truncates at 256 KB.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOG=/usr/local/var/log/netwatch.log

# Wi-Fi device and gateway are resolved, not hardcoded: on another machine the
# radio may be en0, and the router is whatever configd says it is.
IF=$(networksetup -listallhardwareports 2>/dev/null |
  awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
IF=${IF:-en1}
GATEWAY=$(printf 'show State:/Network/Global/IPv4\n' | scutil 2>/dev/null |
  awk -F' : ' '/Router/{print $2; exit}')
if [[ -z $GATEWAY ]]; then
  GATEWAY=$(netstat -rn -f inet 2>/dev/null | awk '/^default/{print $2; exit}')
fi
GATEWAY=${GATEWAY:-192.168.1.1}

BOOT=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}')
CIJ=$(tail -1 /usr/local/var/log/countryinj.log 2>/dev/null)
NW=$(scutil --nwi 2>/dev/null | grep -m1 REACH | sed 's/.*(\(.*\)).*/\1/')
NW=${NW:-none}
G4=$(printf 'show State:/Network/Global/IPv4\n' | scutil 2>/dev/null | awk -F' : ' '/PrimaryInterface/{print $2}')
G4=${G4:-none}
# A synthetic "DHCP-<if>" ServiceID means an interface-level `ipconfig set`
# owns the address instead of the SCNetworkService.  That state survives until
# the next network change and then costs the machine its global state, so it
# is worth recording on every sample.
ADHOC=no
ipconfig getsummary "$IF" 2>/dev/null | grep -q "ServiceID : DHCP-${IF}" && ADHOC=yes
GW=$(ping -c1 -t2 "$GATEWAY" >/dev/null 2>&1 && echo OK || echo FAIL)
WAN=$(ping -c1 -t3 223.5.5.5 >/dev/null 2>&1 && echo OK || echo FAIL)
DNS=$(dscacheutil -q host -a name apple.com 2>/dev/null | grep -c ip_address)
RSSI=$(wdutil info 2>/dev/null | awk '/RSSI/{print $3; exit}')
RSSI=${RSSI:-?}

printf '%s | boot=%s | nwi=%s primary=%s adhoc=%s gw=%s wan=%s dns=%s rssi=%s | %s\n' \
  "$(date '+%F %T')" "$BOOT" "$NW" "$G4" "$ADHOC" "$GW" "$WAN" "$DNS" "$RSSI" "$CIJ" >> "$LOG"

if [[ -f "$LOG" && $(stat -f %z "$LOG" 2>/dev/null) -gt 262144 ]]; then
  tail -c 131072 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
