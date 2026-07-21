#!/bin/bash
# Regression checks for the daily display on/off schedule (rc.aoostar-lcd's
# parse_hhmm + write_cron). The schedule is format-driven: a wrong field order
# or a malformed HH:MM silently produces a crontab line that never fires - the
# exact class of bug CLAUDE.md wants pinned. Run on the Mac in a container:
#   docker run --rm -v "$PWD":/w -w /w bash:5.2 \
#     bash unraid-plugin/src/test/test_cron.sh
set -u
RC="$(dirname "$0")/../plugin-root/scripts/rc.aoostar-lcd"

# source the rc script for its functions only (no command dispatch)
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
check_fails() { # check_fails <description> <command...>
  if "${@:2}" >/dev/null 2>&1; then
    echo "FAIL - $1: expected non-zero exit"
    fail=1
  else
    echo "ok   - $1"
  fi
}

# --- parse_hhmm turns "HH:MM" into a crontab "MM HH" pair ---------------------
# The field order flip is the whole point: crontab is minute-first, the UI is
# hour-first. Getting this backwards is the classic silent schedule bug.
check "23:00 -> minute hour"     "0 23"  "$(parse_hhmm 23:00)"
check "07:05 -> strips 0-pad"    "5 7"   "$(parse_hhmm 07:05)"
check "00:00 midnight"           "0 0"   "$(parse_hhmm 00:00)"
check "9:30 single-digit hour"   "30 9"  "$(parse_hhmm 9:30)"

# 08/09 must not be read as invalid octal (10# guards this)
check "08:09 not octal"          "9 8"   "$(parse_hhmm 08:09)"

# malformed / out-of-range input must be rejected, not coerced
check_fails "empty rejected"          parse_hhmm ""
check_fails "no colon rejected"       parse_hhmm 2300
check_fails "hour 24 rejected"        parse_hhmm 24:00
check_fails "minute 60 rejected"      parse_hhmm 07:60
check_fails "non-numeric rejected"    parse_hhmm "ab:cd"

# --- write_cron emits well-formed cron only when the schedule is on ----------
CRONFILE="$(mktemp)" ; rm -f "$CRONFILE"
PLUGIN="aoostar-lcd"
# stub update_cron out of the picture (path guard already tolerates its absence)

# schedule on: two daily lines, off before on, five time fields + command
SERVICE="enabled" ; SCHEDULE="enabled" ; SCHED_OFF="23:00" ; SCHED_ON="07:00"
write_cron
check "cron written when enabled" "yes" "$([ -f "$CRONFILE" ] && echo yes || echo no)"
off_line=$(grep 'sleep' "$CRONFILE")
on_line=$(grep 'wake' "$CRONFILE")
check "off line = 23:00 sleep" "0 23 * * * /usr/local/emhttp/plugins/aoostar-lcd/scripts/rc.aoostar-lcd sleep &>/dev/null" "$off_line"
check "on line = 07:00 wake"   "0 7 * * * /usr/local/emhttp/plugins/aoostar-lcd/scripts/rc.aoostar-lcd wake &>/dev/null"    "$on_line"

# schedule off: file removed (disabling the schedule must un-schedule it)
SCHEDULE="disabled"
write_cron
check "cron removed when disabled" "no" "$([ -f "$CRONFILE" ] && echo yes || echo no)"

# service disabled beats schedule enabled: no autostart => no schedule
SERVICE="disabled" ; SCHEDULE="enabled"
write_cron
check "no cron when service off" "no" "$([ -f "$CRONFILE" ] && echo yes || echo no)"

# a malformed time leaves no half-written schedule behind
SERVICE="enabled" ; SCHEDULE="enabled" ; SCHED_OFF="nope" ; SCHED_ON="07:00"
write_cron
check "no cron when time malformed" "no" "$([ -f "$CRONFILE" ] && echo yes || echo no)"

exit $fail
