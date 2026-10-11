#!/bin/zsh
# One-shot installer.  Checks the machine is actually able to run this thing,
# then drives the individual steps in order.
#
# The hard prerequisite is SIP: dyld will not honour DYLD_INSERT_LIBRARIES for
# the system daemons this project hooks while System Integrity Protection is
# on, so installing with SIP enabled produces a silently non-working setup.
# That is why this script checks first instead of letting you find out later.
#
# Usage:
#   ./install.sh              check, then install everything
#   ./install.sh --dry-run    check only, change nothing
#   ./install.sh --uninstall  remove everything this project installed
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Without pipefail, `script | tee` reports tee's status and a failing step
# would sail straight through the guard below.
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LOG=/tmp/macos-wifi-country-us-install.log

# ---------------------------------------------------------------- preflight --

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }

DRYRUN=0
UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --dry-run)    DRYRUN=1 ;;
    --uninstall)  UNINSTALL=1 ;;
    -h|--help)    awk '/^# Usage:/{f=1} f{if(!/^#/)exit; sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *)            die "unknown option: $a (try --help)" ;;
  esac
done

say "preflight"

[[ "$(uname -s)" == "Darwin" ]] || die "this only runs on macOS (uname=$(uname -s))"
[[ -d "$HERE/src" && -d "$HERE/scripts" ]] || die "run me from the repo root"

# The reader dylib links against the SDK's IO80211.tbd, which ships with the
# Xcode Command Line Tools.  Without it the reader build fails halfway through
# the install, so check up front.
if ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  die "Xcode Command Line Tools missing -- run: xcode-select --install"
fi
ok "Xcode Command Line Tools"

# SIP.  `csrutil status` prints one of:
#   "System Integrity Protection status: disabled."
#   "System Integrity Protection status: enabled."
#   "... disabled (custom configuration)." when individual features are off.
# Any wording containing "disabled" means the dyld injection can work.
SIP=$(/usr/bin/csrutil status 2>&1)
if print -r -- "$SIP" | /usr/bin/grep -qi "disabled"; then
  ok "SIP disabled -- dyld injection is possible"
else
  printf '  \033[31mFAIL\033[0m SIP is enabled, so this cannot work:\n\n'
  printf '      %s\n\n' "$SIP"
  printf '  With SIP on, dyld ignores DYLD_INSERT_LIBRARIES for the system\n'
  printf '  daemons this project hooks.  Nothing would crash -- the daemons\n'
  printf '  would simply keep reporting CN, and the install would look like\n'
  printf '  it succeeded.  Disabling SIP has to be done from Recovery:\n'
  printf '      reboot holding the power button -> Recovery ->\n'
  printf '      Utilities -> Terminal -> csrutil disable\n'
  printf '  Then reboot back and re-run this script.\n\n'
  exit 1
fi

# sudo.  The individual steps install into /usr/local and /Library, so we need
# it.  Prompt once here rather than failing halfway through a step.
if [[ $DRYRUN -eq 0 ]]; then
  printf '  sudo password: '
  if ! /usr/bin/sudo -v; then
    die "could not obtain sudo -- nothing was installed"
  fi
  ok "sudo"
fi

# ------------------------------------------------------------------ install --

if [[ $UNINSTALL -eq 1 ]]; then
  say "uninstall"
  [[ $DRYRUN -eq 1 ]] && { ok "dry run -- would run scripts/uninstall.sh"; exit 0; }
  exec "$HERE/scripts/uninstall.sh"
fi

# Each entry is "script" or "script|arg".  The script name and its argument are
# kept apart because the invocation below is quoted -- a single
# "restart_daemons.sh --wait" word would be looked up as a filename with a
# space in it.
STEPS=(
  "build_countryus.sh|"
  "build_reader.sh|"
  "install_launchd.sh|"
  "install_wrappers.sh|"
  "restart_daemons.sh|--wait"
)

say "steps"
N=${#STEPS}
i=0
for entry in "${STEPS[@]}"; do
  i=$((i+1))
  s=${entry%%|*}
  arg=${entry#*|}
  # zsh does not brace-expand variables, so a counter instead of {1..$N}.
  if [[ -n "$arg" ]]; then
    printf '  [%d/%d] %s %s\n' "$i" "$N" "$s" "$arg"
  else
    printf '  [%d/%d] %s\n' "$i" "$N" "$s"
  fi
  [[ $DRYRUN -eq 1 ]] && continue

  # Each step is its own zsh script that escalates via sudo itself; the cached
  # credential above means those prompts are already satisfied.  restart_daemons
  # gets --wait so that the verify below does not race the daemon restart.
  if [[ -n "$arg" ]]; then
    "$HERE/scripts/$s" "$arg" 2>&1 | /usr/bin/tee -a "$LOG"
  else
    "$HERE/scripts/$s" 2>&1 | /usr/bin/tee -a "$LOG"
  fi
  if [[ $? -ne 0 ]]; then
    die "step '$s' failed -- full log in $LOG"
  fi
done

if [[ $DRYRUN -eq 1 ]]; then
  say "dry run complete"
  LIST=""
  for entry in "${STEPS[@]}"; do
    s=${entry%%|*}
    arg=${entry#*|}
    LIST="$LIST $s${arg:+ $arg}"
  done
  ok "would run:${LIST}"
  exit 0
fi

# ------------------------------------------------------------------- verify --

say "verify"
if "$HERE/scripts/verify.sh" 2>&1 | /usr/bin/tee -a "$LOG"; then
  ok "done"
  printf '\n  Boot persistence is handled by com.local.countryinj, which re-applies\n'
  printf '  the launchd overrides ~45s after each boot.  To confirm it fired on a\n'
  printf '  given boot, look for its final line in:\n'
  printf '      /usr/local/var/log/countryinj.log\n'
  printf '\n  Note that /tmp is wiped on every macOS boot, so the HOOK_LOADED /\n'
  printf '  SWIZZLE.txt markers under /tmp/opencode/ regenerate after each one.\n'
else
  die "verification reported problems -- see $LOG"
fi
