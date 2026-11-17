#!/bin/bash
# Regression checks for the unraid-stats.sh collector. Run on the Mac in a
# container (no hardware needed - every kernel interface is a mock tree):
#   docker run --rm -v "$PWD":/w -w /w bash:5.2 \
#     bash unraid-plugin/src/test/test_stats.sh
set -u
STATS="$(dirname "$0")/../plugin-root/scripts/unraid-stats.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---- mock kernel/emhttp trees ------------------------------------------------
mk_if() { # mk_if <name> <operstate> <rx_bytes> <tx_bytes>
  mkdir -p "$T/net/$1/statistics"
  echo "$2" > "$T/net/$1/operstate"
  echo "$3" > "$T/net/$1/statistics/rx_bytes"
  echo "$4" > "$T/net/$1/statistics/tx_bytes"
}
set_uptime() { echo "$1 0.00" > "$T/uptime"; }

mkdir -p "$T/run/sensors" "$T/block/sdx/queue" "$T/hwmon" "$T/drm/card0/device"
echo 42 > "$T/drm/card0/device/gpu_busy_percent"
echo 0 > "$T/block/sdx/queue/rotational"
mk_if br0  up   1000000 500000
mk_if eth3 down 0 0
mk_if wg0  up   0 0
# two default routes: the lower metric (br0) must win
printf '%s\n' \
  'Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT' \
  'wg0	00000000	0139A8C0	0003	0	0	2000	00000000	0	0	0' \
  'br0	00000000	0139A8C0	0003	0	0	1012	00000000	0	0	0' \
  'docker0	000011AC	00000000	0001	0	0	0	0000FFFF	0	0	0' > "$T/route"
printf '%s\n' \
  'cpu_usage_percent: 23.95' 'mem_usage_percent: 53.4' \
  'temperature_cpu:   74.0  ' 'temperature_cpu#unit: °C' \
  'storage_hdd[0]_usage_percent: 99' > "$T/run/sensors/sysinfo.txt"
cat > "$T/disks.ini" <<'EOF'
["parity"]
device="sdh"
rotational="1"
temp="*"
["disk1"]
device="sdf"
rotational="1"
temp="43"
["cache"]
device="nvme1n1"
rotational="0"
temp="39"
["flash"]
device="sda"
temp="*"
EOF
set_uptime 1000.00

export RUNDIR="$T/run" DISKS_INI="$T/disks.ini" SYS_NET="$T/net" \
       SYS_BLOCK="$T/block" SYS_HWMON="$T/hwmon" SYS_DRM="$T/drm" \
       PROC_ROUTE="$T/route" PROC_UPTIME="$T/uptime"

# source the collector for its functions only (no loop)
NETIF=auto REFRESH=3 GRAPH_MIN=15
AOOSTAR_LCD_LIB=1 . "$STATS"
# the one external lookup: stub it so no test depends on a real `ip`
iface_ip() { NET_IP="192.0.2.10"; }

fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1: expected [$2] got [$3]"
    fail=1
  fi
}
val() { # val <key>: value of a key in the published sensor file
  local line
  line=$(grep "^$1:" "$OUT") || { echo "<missing>"; return; }
  line=${line#*:}; echo "${line# }"
}

# --- interface selection -----------------------------------------------------
# Original symptom: the panel showed "0 B/s", a 0 peak and a blank IP for an
# hour. aster-sysinfo only reports physical NICs, so the default NETIF=br0
# yielded nothing, and the hand-picked replacement was an unplugged port.
# auto must follow the default route, and the lowest metric must win.
resolve_netif
check "auto follows lowest-metric default route" "br0" "$IFACE"
NETIF=eth3 ; resolve_netif
check "explicit NETIF is respected" "eth3" "$IFACE"
NETIF=auto PROC_ROUTE="$T/none" ; resolve_netif
check "no default route -> no interface" "" "$IFACE"
PROC_ROUTE="$T/route"

# --- rates come from the kernel counters -------------------------------------
NETIF=auto
collect_once
check "first sample has no delta yet" "0 B/s" "$(val net_down)"
# 3.00 s later: +3 MiB received, +1536 bytes sent
mk_if br0 up $((1000000 + 3 * 1048576)) $((500000 + 1536))
set_uptime 1003.00
collect_once
check "download rate from rx delta / elapsed" "1.0 MB/s" "$(val net_down)"
check "upload rate from tx delta / elapsed"   "512 B/s"  "$(val net_up)"
check "address shown"                         "192.0.2.10" "$(val net_ip)"
# the loop runs late (6 s instead of 3): the rate must use real elapsed time,
# not the nominal REFRESH - same bytes over twice the time = half the rate
mk_if br0 up $((1000000 + 6 * 1048576)) $((500000 + 1536))
set_uptime 1009.00
collect_once
check "rate uses measured elapsed time" "512 KB/s" "$(val net_down)"
# counters reset (interface recreated): never a negative/huge bogus rate
mk_if br0 up 10 10
set_uptime 1012.00
collect_once
check "counter reset yields 0, not garbage" "0 B/s" "$(val net_down)"

# --- a dead interface says so ------------------------------------------------
# "0 B/s" on an unplugged port is indistinguishable from an idle link - the
# exact confusion in the original photo. The panel must name the problem.
keys_ok=$(grep -o '^[a-z_]*:' "$OUT" | sort | tr '\n' ' ')
NETIF=eth3
collect_once
check "link down is reported"           "eth3 link down" "$(val net_ip)"
check "no speed claimed when link down" "--"             "$(val net_up)"
NETIF=eth9
collect_once
check "missing interface is reported"   "eth9 not found" "$(val net_ip)"
NETIF=auto PROC_ROUTE="$T/none"
collect_once
check "no default route is reported"    "no default route" "$(val net_ip)"
PROC_ROUTE="$T/route"
# asterctl never drops absent keys: the error states must rewrite the exact
# same key set as the healthy state, or stale values would stay on screen
keys_bad=$(grep -o '^[a-z_]*:' "$OUT" | sort | tr '\n' ' ')
check "error state writes the same keys as the healthy state" "$keys_ok" "$keys_bad"

# --- humanize ----------------------------------------------------------------
h() { humanize "$1"; echo "$HUMAN"; }
check "bytes"                  "0 B/s"     "$(h 0)"
check "below 1 KiB"            "1023 B/s"  "$(h 1023)"
check "one decimal below 100"  "13.8 KB/s" "$(h 14172)"
check "no decimal from 100"    "512 KB/s"  "$(h 524288)"
check "megabytes"              "1.0 MB/s"  "$(h 1048576)"
check "gigabytes"              "2.5 GB/s"  "$(h 2684354560)"

# --- history: constant cost, whatever the window -----------------------------
# The old ring buffer kept every sample (GRAPH_MIN*60/REFRESH of them) and
# copied + rescanned it each cycle: 68 ms/cycle at 60 min, and at the
# settings page's maximum (1440 min, 1 s) a cycle took longer than the
# refresh interval. State must stay GRAPH_BUCKETS long regardless.
GRAPH_MIN=1440 REFRESH=1
hist_init
NOW_CS=0
for ((i = 0; i < 5000; i++)); do
  NOW_CS=$(( i * 100 ))
  hist_push $(( i % 7 )) 1
done
check "history stays GRAPH_BUCKETS long (1440 min @ 1 s)" \
      "$GRAPH_BUCKETS $GRAPH_BUCKETS" "${#UP_B[@]} ${#DOWN_B[@]}"

# bucket semantics: 26 buckets over 26 minutes = 60 s each
GRAPH_MIN=26 REFRESH=3
hist_init
NOW_CS=100000 ; hist_push 500 0
NOW_CS=100300 ; hist_push 900 0        # same bucket: the peak is kept
NOW_CS=100600 ; hist_push 200 0
last=$(( GRAPH_BUCKETS - 1 ))
check "bucket keeps its peak, not the latest sample" "900" "${UP_B[last]}"
NOW_CS=106000 ; hist_push 100 0        # 60 s after the first sample: next bucket
check "window advances one bucket per slice" "900 100" "${UP_B[last-1]} ${UP_B[last]}"
NOW_CS=$(( 106000 + 3 * 6000 )) ; hist_push 0 0
check "idle slices shift in as zeros" "900 100 0 0 0" \
      "${UP_B[last-4]} ${UP_B[last-3]} ${UP_B[last-2]} ${UP_B[last-1]} ${UP_B[last]}"
NOW_CS=$(( NOW_CS + 100 * 6000 )) ; hist_push 7 0
sparkline UP_B
check "a gap longer than the window clears the history" "7" "$PEAK"

# --- sparkline scale ---------------------------------------------------------
# With the old linear scale one burst flattened everything else to the
# baseline glyph. sqrt scale + a floor of level 1 keeps light traffic
# visible, while true zero stays on the baseline.
lvl() { spark_level "$1" "$2"; echo "$LEVEL"; }
check "zero is the baseline"            "0" "$(lvl 0 1000000)"
check "the peak is full height"         "7" "$(lvl 1000000 1000000)"
check "0.1% of peak is still visible"   "1" "$(lvl 1000 1000000)"
check "25% of peak is mid-height (sqrt)" "3" "$(lvl 250000 1000000)"
check "no traffic at all: flat baseline" "0" "$(lvl 0 0)"
hist_init ; NOW_CS=0 ; hist_push 1000000 0
sparkline UP_B
check "sparkline is exactly GRAPH_BUCKETS glyphs" "$GRAPH_BUCKETS" "${#SPARK}"
check "newest bucket is the rightmost glyph" "█" "${SPARK: -1}"

# --- disks -------------------------------------------------------------------
HDD_HOT=45 SSD_HOT=60
read_disks
check "disk summary counts" "hdd=1/43 ssd=1/39 standby=1" \
      "hdd=$hdd_n/$hdd_max ssd=$ssd_n/$ssd_max standby=$standby"
HDD_HOT=40 ; read_disks
check "hot disk is listed" "disk1 43°C" "$hot_list"
HDD_HOT=45
# older Unraid: no rotational= in disks.ini -> sysfs, read once and cached
is_ssd sdx "" && r=ssd || r=hdd
check "rotational falls back to sysfs" "ssd" "$r"
echo 1 > "$T/block/sdx/queue/rotational"
is_ssd sdx "" && r=ssd || r=hdd
check "sysfs rotational is cached, not re-read" "ssd" "$r"

# --- the cycle is fork-free --------------------------------------------------
# The old loop forked ~12 processes per cycle (awk for unit maths, cat for
# every sysfs file). Run a full cycle with a PATH that contains nothing but
# `mv` (the atomic publish): any other external command would fail to launch
# and leave its value empty or wrong.
mkdir -p "$T/bin"
ln -s "$(command -v mv)" "$T/bin/mv"
NETIF=auto GRAPH_MIN=15 REFRESH=3
hist_init
mk_if br0 up 0 0 ; set_uptime 2000.00
rm -f "$OUT"
# (a subshell keeps the stripped PATH scoped to the two cycles)
( PATH="$T/bin"
  collect_once
  echo 3145728 > "$T/net/br0/statistics/rx_bytes" ; set_uptime 2003.00
  collect_once ) 2> "$T/err"
check "no external command needed (stderr clean)" "" "$(cat "$T/err")"
check "builtins-only cycle: speed"  "1.0 MB/s" "$(val net_down)"
check "builtins-only cycle: cpu"    "23%"      "$(val cpu_util_g)"
check "builtins-only cycle: temp"   "74°C"     "$(val cpu_temp_a)"
check "builtins-only cycle: gpu"    "42%"      "$(val gpu_util_g)"
check "builtins-only cycle: disks"  "HDD max 43°C   ·   SSD max 39°C   ·   1 standby" "$(val disk_ok)"

echo
[ "$fail" = "0" ] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit "$fail"
