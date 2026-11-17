#!/bin/bash
# unraid-stats.sh - Unraid-specific sensor collector for the aoostar-lcd
# "Unraid Dark" panel.
#
# Reads aster-sysinfo's output (CPU, RAM, temperatures), the kernel's own
# network counters, and Unraid's disk state (/var/local/emhttp/disks.ini -
# temperatures cached by emhttp, so spun-down disks are NEVER woken) and
# writes panel-ready values to $RUNDIR/sensors/unraid.txt (atomic rename).
#
# Dynamic colors: each colored value has three label "slots" (_g/_a/_r);
# every slot is (re)written each cycle with only one non-empty - empty
# values render nothing, and overwriting is required because asterctl's
# sensor map never removes keys that disappear from the file.
#
# Network: speeds come from /sys/class/net/<if>/statistics, not from
# aster-sysinfo - that only reports physical NICs (no br0/bond0) and no
# address, so the Unraid default bridge showed nothing. NETIF=auto follows
# the default route. A missing or down interface is reported as such instead
# of a confident "0 B/s".
#
# Network history: samples are folded into GRAPH_BUCKETS time buckets as they
# arrive (per-bucket peak), so the cost per cycle is constant no matter how
# long the GRAPH_MIN window is. Rendered as block-element sparklines.
#
# The loop is deliberately fork-free apart from the final `mv`, the `sleep`
# and an occasional `ip` (see IP_EVERY): everything else is bash builtins.
#
# Configuration comes from the environment (set by rc.aoostar-lcd):
#   NETIF REFRESH CPU_TEMP_WARN CPU_TEMP_HOT HDD_HOT SSD_HOT
#   CPU_TEMP_SENSOR GRAPH_MIN

RUNDIR="${RUNDIR:-/run/aoostar-lcd}"
SYSINFO="${SYSINFO:-$RUNDIR/sensors/sysinfo.txt}"
OUT="${OUT:-$RUNDIR/sensors/unraid.txt}"
TMP="${TMP:-$RUNDIR/.unraid.txt.tmp}"
DISKS_INI="${DISKS_INI:-/var/local/emhttp/disks.ini}"
# kernel interfaces - overridable so tests can point at mock trees
SYS_NET="${SYS_NET:-/sys/class/net}"
SYS_BLOCK="${SYS_BLOCK:-/sys/block}"
SYS_HWMON="${SYS_HWMON:-/sys/class/hwmon}"
SYS_DRM="${SYS_DRM:-/sys/class/drm}"
PROC_ROUTE="${PROC_ROUTE:-/proc/net/route}"
PROC_UPTIME="${PROC_UPTIME:-/proc/uptime}"

NETIF="${NETIF:-auto}"
REFRESH="${REFRESH:-3}"
CPU_TEMP_WARN="${CPU_TEMP_WARN:-70}"
CPU_TEMP_HOT="${CPU_TEMP_HOT:-85}"
UTIL_WARN="${UTIL_WARN:-70}"
UTIL_HOT="${UTIL_HOT:-90}"
HDD_HOT="${HDD_HOT:-45}"
SSD_HOT="${SSD_HOT:-60}"
CPU_TEMP_SENSOR="${CPU_TEMP_SENSOR:-auto}"
GRAPH_MIN="${GRAPH_MIN:-15}"

GRAPH_BUCKETS=26
LEVELS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
# the address rarely changes and reading it costs a fork: refresh it only
# every IP_EVERY cycles (and whenever the interface changes)
IP_EVERY=20

# ------------------------------------------------------------------- helpers

# now_cs: sets NOW_CS to a monotonic clock in centiseconds. /proc/uptime is
# read with a builtin (no fork) and is immune to NTP/timezone jumps.
now_cs() {
  local up=0
  { read -r up _ < "$PROC_UPTIME"; } 2>/dev/null
  NOW_CS=$(( 10#${up/./} ))
}

# readf <file>: sets REPLY to the first line of a file ("" if unreadable)
# without forking `cat`.
readf() {
  REPLY=""
  { read -r REPLY < "$1"; } 2>/dev/null
  return 0
}

# humanize <bytes/s>: sets HUMAN to a short fixed-shape string such as
# "13.8 MB/s" - one decimal below 100, none above, so the value does not
# jitter between widths. Integer maths only.
humanize() {
  local v=$1 d=1 i=0 tenths
  local units=(B KB MB GB TB)
  while (( v >= d * 1024 && i < 4 )); do
    d=$(( d * 1024 )); i=$(( i + 1 ))
  done
  if (( i == 0 )); then
    HUMAN="$v B/s"
    return
  fi
  tenths=$(( (v * 10 + d / 2) / d ))
  if (( tenths >= 1000 )); then
    HUMAN="$(( (tenths + 5) / 10 )) ${units[i]}/s"
  else
    HUMAN="$(( tenths / 10 )).$(( tenths % 10 )) ${units[i]}/s"
  fi
}

# slot: <label> <value> <warn> <hot> <suffix>
# Emits ALL three color slots every cycle - the active one with the
# formatted value, the others empty. asterctl's sensor map accumulates
# keys (absent keys are never removed), so an empty overwrite is the only
# way to clear a previously used slot; empty values render nothing.
slot() {
  local label="$1" value="$2" warn="$3" hot="$4" suffix="$5" int active="g"
  if [ -n "$value" ]; then
    int=${value%%.*}
    if [ "$int" -ge "$hot" ] 2>/dev/null; then
      active="r"
    elif [ "$int" -ge "$warn" ] 2>/dev/null; then
      active="a"
    fi
  fi
  local c
  for c in g a r; do
    if [ "$c" = "$active" ] && [ -n "$value" ]; then
      echo "${label}_${c}: ${value}${suffix}"
    else
      echo "${label}_${c}:"
    fi
  done
}

# ------------------------------------------------------------ sysinfo values

# read aster-sysinfo's "key: value" file into S[]
declare -A S
read_sysinfo() {
  local key val
  S=()
  [ -f "$SYSINFO" ] || return 0
  while IFS=: read -r key val; do
    # the file has ~200 lines and the panel needs a handful: skip the rest
    # before doing any string work (this loop dominated the cycle time)
    case "$key" in
      cpu_usage_percent|mem_usage_percent|temperature_*|"$CPU_TEMP_SENSOR") ;;
      *) continue ;;
    esac
    # "key: value" - strip the separator space; the full (slow) trim only
    # runs for the rare value that still has surrounding whitespace
    val=${val# }
    case "$val" in
      [[:space:]]*|*[[:space:]])
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}" ;;
    esac
    S[$key]="$val"
  done < "$SYSINFO"
}

cpu_temp_from_hwmon() {
  # fallback: read k10temp (AMD) / coretemp (Intel) directly from sysfs
  local hw
  CPUTEMP=""
  for hw in "$SYS_HWMON"/hwmon*; do
    readf "$hw/name"
    case "$REPLY" in
      k10temp|coretemp|zenpower)
        readf "$hw/temp1_input"
        [ -n "$REPLY" ] && CPUTEMP=$(( REPLY / 1000 )) && return
        ;;
    esac
  done
}

# sets CPUTEMP
read_cpu_temp() {
  local k
  CPUTEMP=""
  if [ "$CPU_TEMP_SENSOR" != "auto" ]; then
    CPUTEMP="${S[$CPU_TEMP_SENSOR]}"
    return
  fi
  for k in temperature_cpu temperature_k10temp_Tctl temperature_k10temp \
           temperature_Tctl temperature_coretemp_Package_id_0; do
    [ -n "${S[$k]}" ] && CPUTEMP="${S[$k]}" && return
  done
  for k in "${!S[@]}"; do
    case "$k" in
      temperature_*k10temp*|temperature_*coretemp*|temperature_*Tctl*)
        [ "${k%"#unit"}" = "$k" ] && CPUTEMP="${S[$k]}" && return ;;
    esac
  done
  cpu_temp_from_hwmon
}

# sets GPUUTIL (amdgpu iGPU, same die as the CPU)
read_gpu_util() {
  local f
  GPUUTIL=""
  for f in "$SYS_DRM"/card*/device/gpu_busy_percent; do
    [ -f "$f" ] || continue
    readf "$f"
    GPUUTIL=$REPLY
    return
  done
}

# ------------------------------------------------------------------- network

# resolve_netif: sets IFACE. NETIF=auto follows the IPv4 default route
# (lowest metric wins), which is the interface that actually carries the
# server's traffic - br0 on a stock Unraid, bond0/eth0 without bridging.
resolve_netif() {
  local ifc dest gw flags ref use metric mask rest best=""
  if [ "$NETIF" != "auto" ]; then
    IFACE=$NETIF
    return
  fi
  IFACE=""
  [ -r "$PROC_ROUTE" ] || return 0
  while read -r ifc dest gw flags ref use metric mask rest; do
    [ "$dest" = "00000000" ] && [ "$mask" = "00000000" ] || continue
    if [ -z "$best" ] || (( metric < best )); then
      best=$metric
      IFACE=$ifc
    fi
  done < "$PROC_ROUTE"
}

# iface_ip <if>: sets NET_IP to the interface's first IPv4 address ("" if
# none). The only fork in the network path - see IP_EVERY.
iface_ip() {
  local line addr
  NET_IP=""
  line=$(ip -4 -o addr show dev "$1" 2>/dev/null) || return 0
  # "5: br0    inet 192.168.57.10/24 brd 192.168.57.255 scope global br0"
  read -r _ _ _ addr _ <<< "$line"
  NET_IP=${addr%/*}
}

# net_sample: sets NET_STATE ("ok" or a human-readable problem), and
# NET_UP / NET_DOWN in bytes/s from the counter deltas since the last call.
# The first sample after a (re)start or interface change reports 0.
PREV_IF="" PREV_CS=0 PREV_RX=0 PREV_TX=0
net_sample() {
  local dir="$SYS_NET/$IFACE" rx tx dt
  NET_UP=0 NET_DOWN=0
  if [ -z "$IFACE" ]; then
    NET_STATE="no default route"; PREV_IF=""; return
  fi
  if [ ! -d "$dir" ]; then
    NET_STATE="$IFACE not found"; PREV_IF=""; return
  fi
  readf "$dir/operstate"
  case "$REPLY" in
    down|lowerlayerdown|notpresent)
      NET_STATE="$IFACE link down"; PREV_IF=""; return ;;
  esac
  readf "$dir/statistics/rx_bytes"; rx=${REPLY:-0}
  readf "$dir/statistics/tx_bytes"; tx=${REPLY:-0}
  # counters going backwards = interface was recreated: skip this delta
  if [ "$PREV_IF" = "$IFACE" ] \
     && (( NOW_CS > PREV_CS && rx >= PREV_RX && tx >= PREV_TX )); then
    dt=$(( NOW_CS - PREV_CS ))
    NET_DOWN=$(( (rx - PREV_RX) * 100 / dt ))
    NET_UP=$(( (tx - PREV_TX) * 100 / dt ))
  fi
  PREV_IF=$IFACE PREV_CS=$NOW_CS PREV_RX=$rx PREV_TX=$tx
  NET_STATE="ok"
}

# ----------------------------------------------------------- network history

# Fixed-size bucket arrays: index GRAPH_BUCKETS-1 is the bucket currently
# being filled, older buckets shift left. Each holds the peak bytes/s seen
# during its BUCKET_CS slice of the window.
hist_init() {
  local i
  BUCKET_CS=$(( GRAPH_MIN * 6000 / GRAPH_BUCKETS ))
  # a bucket shorter than the sample interval would stay empty between samples
  (( BUCKET_CS < REFRESH * 100 )) && BUCKET_CS=$(( REFRESH * 100 ))
  UP_B=() DOWN_B=()
  for (( i = 0; i < GRAPH_BUCKETS; i++ )); do
    UP_B+=(0); DOWN_B+=(0)
  done
  BUCKET_T=""
}

# hist_push <up> <down>: fold one sample into the current bucket, first
# advancing the window to NOW_CS. O(GRAPH_BUCKETS) at worst, never O(samples).
hist_push() {
  local up=$1 down=$2 last=$(( GRAPH_BUCKETS - 1 )) steps
  [ -z "$BUCKET_T" ] && BUCKET_T=$NOW_CS
  steps=$(( (NOW_CS - BUCKET_T) / BUCKET_CS ))
  if (( steps >= GRAPH_BUCKETS )); then
    # nothing recorded for a whole window (e.g. the box was suspended)
    hist_init
    BUCKET_T=$NOW_CS
  else
    while (( steps-- > 0 )); do
      UP_B=("${UP_B[@]:1}" 0)
      DOWN_B=("${DOWN_B[@]:1}" 0)
      BUCKET_T=$(( BUCKET_T + BUCKET_CS ))
    done
  fi
  (( up > UP_B[last] )) && UP_B[last]=$up
  (( down > DOWN_B[last] )) && DOWN_B[last]=$down
  return 0
}

# spark_level <value> <max>: sets LEVEL (index into LEVELS).
# Square-root scale: with a linear one a single burst flattens everything
# else to the baseline. Any non-zero traffic gets at least level 1, so
# "idle" and "some traffic" stay distinguishable next to a large peak.
spark_level() {
  local v=$1 max=$2 l=0
  LEVEL=0
  (( v <= 0 || max <= 0 )) && return 0
  # largest l in 0..7 with (l/7)^2 <= v/max
  while (( l < 7 && (l + 1) * (l + 1) * max <= 49 * v )); do
    l=$(( l + 1 ))
  done
  (( l < 1 )) && l=1
  LEVEL=$l
}

# sparkline <bucket-array-name>: sets SPARK (GRAPH_BUCKETS block chars) and
# PEAK (window max, bytes/s)
sparkline() {
  local -n _arr=$1
  local v max=0
  for v in "${_arr[@]}"; do
    (( v > max )) && max=$v
  done
  PEAK=$max
  SPARK=""
  for v in "${_arr[@]}"; do
    spark_level "$v" "$max"
    SPARK+="${LEVELS[LEVEL]}"
  done
}

# --------------------------------------------------------------------- disks

declare -A ROT_CACHE
# is_ssd <device> <rotational-from-disks.ini>: true for non-rotational media.
# disks.ini carries the flag on current Unraid; older releases need sysfs,
# which is read once per device and cached (it never changes).
is_ssd() {
  local dev=$1 rot=$2
  case "$dev" in nvme*) return 0 ;; esac
  if [ -z "$rot" ]; then
    if [ -z "${ROT_CACHE[$dev]+x}" ]; then
      readf "$SYS_BLOCK/$dev/queue/rotational"
      ROT_CACHE[$dev]=${REPLY:-1}
    fi
    rot=${ROT_CACHE[$dev]}
  fi
  [ "$rot" = "0" ]
}

flush_disk() {
  local limit
  [ -z "$d_dev" ] && return
  case "$d_name" in flash|"") d_dev=""; return ;; esac
  if [ "$d_temp" = "*" ] || [ -z "$d_temp" ]; then
    standby=$(( standby + 1 )); d_dev=""; return
  fi
  if is_ssd "$d_dev" "$d_rot"; then
    ssd_n=$(( ssd_n + 1 )); [ "$d_temp" -gt "$ssd_max" ] && ssd_max=$d_temp
    limit=$SSD_HOT
  else
    hdd_n=$(( hdd_n + 1 )); [ "$d_temp" -gt "$hdd_max" ] && hdd_max=$d_temp
    limit=$HDD_HOT
  fi
  if [ "$d_temp" -ge "$limit" ] 2>/dev/null; then
    hot_list="$hot_list, $d_name ${d_temp}°C"
  fi
  d_dev=""
}

# temperatures from emhttp's cache (never wakes disks); sets hdd_max ssd_max
# hdd_n ssd_n standby hot_list
read_disks() {
  local line
  hdd_max=0 ssd_max=0 hdd_n=0 ssd_n=0 standby=0 hot_list=""
  d_name="" d_dev="" d_temp="" d_rot=""
  [ -f "$DISKS_INI" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      \[*\])   flush_disk; d_name="${line#[\"}"; d_name="${d_name%\"]}"
               d_name="${d_name#[}"; d_name="${d_name%]}"
               d_dev="" d_temp="" d_rot="" ;;
      device=*)     d_dev="${line#device=}"; d_dev="${d_dev//\"/}" ;;
      temp=*)       d_temp="${line#temp=}"; d_temp="${d_temp//\"/}" ;;
      rotational=*) d_rot="${line#rotational=}"; d_rot="${d_rot//\"/}" ;;
    esac
  done < "$DISKS_INI"
  flush_disk
  hot_list="${hot_list#, }"
}

# -------------------------------------------------------------------- output

write_panel() {
  local summary
  echo "# generated by unraid-stats.sh"
  # static captions (rendered by asterctl as plain text sensors)
  echo "lbl_cpu: CPU / GPU"
  echo "lbl_cpu_cap: CPU"
  echo "lbl_gpu_cap: GPU"
  echo "lbl_ram: RAM"
  echo "lbl_net: NETWORK"
  echo "lbl_up: ▲"
  echo "lbl_down: ▼"
  echo "lbl_ip: IP"

  slot cpu_util "${S[cpu_usage_percent]%%.*}" "$UTIL_WARN" "$UTIL_HOT" "%"
  slot gpu_util "${GPUUTIL%%.*}" "$UTIL_WARN" "$UTIL_HOT" "%"
  slot cpu_temp "${CPUTEMP%%.*}" "$CPU_TEMP_WARN" "$CPU_TEMP_HOT" "°C"
  echo "mem_pct: ${S[mem_usage_percent]%%.*}%"

  # always write every key so an interface change can never leave stale
  # values. A broken interface shows its problem instead of "0 B/s", which
  # is indistinguishable from an idle link.
  if [ "$NET_STATE" = "ok" ]; then
    humanize "$NET_UP";   echo "net_up: $HUMAN"
    humanize "$NET_DOWN"; echo "net_down: $HUMAN"
    echo "net_ip: ${NET_IP:-no IPv4 on $IFACE}"
  else
    echo "net_up: --"
    echo "net_down: --"
    echo "net_ip: $NET_STATE"
  fi

  sparkline UP_B
  humanize "$PEAK"
  echo "net_up_graph: $SPARK"
  echo "net_up_peak: $HUMAN peak"
  sparkline DOWN_B
  humanize "$PEAK"
  echo "net_down_graph: $SPARK"
  echo "net_down_peak: $HUMAN peak"
  echo "lbl_window: last ${GRAPH_MIN} min"

  # always write both keys: one empty, to clear the stale counterpart
  if [ -n "$hot_list" ]; then
    echo "disk_alert: ⚠ DISK HOT: $hot_list"
    echo "disk_ok:"
  else
    summary=""
    [ "$hdd_n" -gt 0 ] && summary="HDD max ${hdd_max}°C"
    [ "$ssd_n" -gt 0 ] && summary="${summary:+$summary   ·   }SSD max ${ssd_max}°C"
    [ "$standby" -gt 0 ] && summary="${summary:+$summary   ·   }$standby standby"
    echo "disk_ok: ${summary:-disks: no data}"
    echo "disk_alert:"
  fi
}

# one full collection cycle: gather everything, then publish atomically
CYCLE=0 IP_IF=""
collect_once() {
  now_cs
  read_sysinfo
  read_cpu_temp
  read_gpu_util

  resolve_netif
  net_sample
  if [ "$NET_STATE" = "ok" ]; then
    if [ "$IFACE" != "$IP_IF" ] || (( CYCLE % IP_EVERY == 0 )); then
      iface_ip "$IFACE"
      IP_IF=$IFACE
    fi
  else
    IP_IF=""
  fi
  hist_push "$NET_UP" "$NET_DOWN"

  read_disks

  write_panel > "$TMP"
  mv -f "$TMP" "$OUT"
  CYCLE=$(( CYCLE + 1 ))
}

hist_init

# tests source this file to exercise the functions above without starting
# the collection loop
[ -n "${AOOSTAR_LCD_LIB:-}" ] && return 0

while :; do
  collect_once
  sleep "$REFRESH"
done
