#!/bin/bash
# Regression checks for plugin updates taking effect (rc.aoostar-lcd upgrade,
# called by install.sh). Run on the Mac in a container:
#   docker run --rm -v "$PWD":/w -w /w bash:5.2 \
#     bash unraid-plugin/src/test/test_upgrade.sh
#
# Original symptom: after `plugin update` the display kept showing the old
# panel and the old collector kept running. install.sh called `start`, which
# returns at "already running" - before seed_cfg installs the new panel - and
# the running bash still had the previous collector script in memory.
set -u
SRC="$(dirname "$0")/.."
RC="$SRC/plugin-root/scripts/rc.aoostar-lcd"

AOOSTAR_LCD_LIB=1 . "$RC"

fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected [$2] got [$3]"
    fail=1
  fi
}

# record what upgrade() does without touching real daemons
calls=""
stop()  { calls="$calls stop"; }
start() { calls="$calls start"; }

# an update: the previous version is running and must be replaced, in order
running() { return 0; }
calls="" ; upgrade
check "running service is stopped, then started" " stop start" "$calls"

# a boot (or first install): nothing to stop, just start
running() { return 1; }
calls="" ; upgrade
check "stopped service is only started" " start" "$calls"

# the linkage: install.sh must use the verb that replaces a running service,
# and the rc script must dispatch it
verb=$(grep -o 'rc\.aoostar-lcd [a-z]*$' "$SRC/install.sh")
check "install.sh runs the upgrade verb" "rc.aoostar-lcd upgrade" "$verb"
check "rc script dispatches upgrade" "1" "$(grep -c '^  upgrade)$' "$RC")"

echo
[ "$fail" = "0" ] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit "$fail"
