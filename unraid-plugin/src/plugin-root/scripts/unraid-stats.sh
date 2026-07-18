#!/bin/bash
# unraid-stats.sh - Unraid-specific sensor collector for the aoostar-lcd
# "Unraid Dark" panel.
#
# Reads aster-sysinfo's output plus Unraid's own disk state
# (/var/local/emhttp/disks.ini - temperatures cached by emhttp, so spun-down
# disks are NEVER woken) and writes panel-ready values to
# $RUNDIR/sensors/unraid.txt (atomic rename).
#
# Dynamic colors: each colored value has three label "slots" (_g/_a/_r);
# every slot is (re)written each cycle with only one non-empty - empty
# values render nothing, and overwriting is required because asterctl's
# sensor map never removes keys that disappear from the file.
#
# Network history: keeps a ring buffer of up/down speeds over GRAPH_MIN
# minutes and renders block-element sparklines (auto-scaled to the window
# peak) as text sensors.
#
# Configuration comes from the environment (set by rc.aoostar-lcd):
#   NETIF REFRESH CPU_TEMP_WARN CPU_TEMP_HOT HDD_HOT SSD_HOT
#   CPU_TEMP_SENSOR GRAPH_MIN

RUNDIR="${RUNDIR:-/run/aoostar-lcd}"
SYSINFO="$RUNDIR/sensors/sysinfo.txt"
OUT="$RUNDIR/sensors/unraid.txt"
TMP="$RUNDIR/.unraid.txt.tmp"
DISKS_INI="${DISKS_INI:-/var/local/emhttp/disks.ini}"

NETIF="${NETIF:-br0}"
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
MAX_SAMPLES=$(( GRAPH_MIN * 60 / REFRESH ))
[ "$MAX_SAMPLES" -lt "$GRAPH_BUCKETS" ] && MAX_SAMPLES=$GRAPH_BUCKETS
UP_HIST=()
DOWN_HIST=()

# "13.84 KB/s" (aster-sysinfo format, 1024-based) -> integer bytes/s
to_bps() {
  local num="${1%% *}" unit="${1#* }" mult=1
  case "$unit" in
    KB/s) mult=1024 ;;
    MB/s) mult=1048576 ;;
    GB/s) mult=1073741824 ;;
    TB/s) mult=1099511627776 ;;
  esac
  awk -v n="$num" -v m="$mult" 'BEGIN{printf "%.0f", n*m}' 2>/dev/null || echo 0
}

# integer bytes/s -> short human string like "13.8K/s"
humanize() {
  awk -v b="$1" 'BEGIN{
    v=b; u="B"
    if (v>=1024) {v/=1024; u="K"}
    if (v>=1024) {v/=1024; u="M"}
    if (v>=1024) {v/=1024; u="G"}
    if (v>=100 || u=="B") printf "%.0f%s/s", v, u
    else printf "%.1f%s/s", v, u
  }'
}

# sparkline <array-name>: sets SPARK (block chars, GRAPH_BUCKETS wide,
# left-padded with baseline for missing history) and PEAK (window max bytes/s)
sparkline() {
  local -n _arr=$1
  local n=${#_arr[@]} max=0 v b j idx bmax start end
  for v in "${_arr[@]}"; do
    [ "$v" -gt "$max" ] 2>/dev/null && max=$v
  done
  PEAK=$max
  SPARK=""
  for ((b = 0; b < GRAPH_BUCKETS; b++)); do
    start=$(( b * MAX_SAMPLES / GRAPH_BUCKETS ))
    end=$(( (b + 1) * MAX_SAMPLES / GRAPH_BUCKETS ))
    bmax=0
    for ((j = start; j < end; j++)); do
      idx=$(( j - (MAX_SAMPLES - n) ))
      if (( idx >= 0 && idx < n )); then
        v=${_arr[idx]}
        (( v > bmax )) && bmax=$v
      fi
    done
    if (( max > 0 )); then
      SPARK+="${LEVELS[bmax * 7 / max]}"
    else
      SPARK+="${LEVELS[0]}"
    fi
  done
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

cpu_temp_from_hwmon() {
  # fallback: read k10temp (AMD) / coretemp (Intel) directly from sysfs
  local hw name t
  for hw in /sys/class/hwmon/hwmon*; do
    name=$(cat "$hw/name" 2>/dev/null)
    case "$name" in
      k10temp|coretemp|zenpower)
        t=$(cat "$hw"/temp1_input 2>/dev/null)
        [ -n "$t" ] && echo $((t / 1000)) && return
        ;;
    esac
  done
}

while :; do
  # ---- read aster-sysinfo values into S[] -------------------------------
  unset S; declare -A S
  if [ -f "$SYSINFO" ]; then
    while IFS=: read -r key val; do
      [ -z "$key" ] || [ "${key:0:1}" = "#" ] && continue
      key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      S[$key]="$val"
    done < "$SYSINFO"
  fi

  # ---- CPU temperature source ------------------------------------------
  cputemp=""
  if [ "$CPU_TEMP_SENSOR" != "auto" ]; then
    cputemp="${S[$CPU_TEMP_SENSOR]}"
  else
    for k in temperature_cpu temperature_k10temp_Tctl temperature_k10temp \
             temperature_Tctl temperature_coretemp_Package_id_0; do
      [ -n "${S[$k]}" ] && cputemp="${S[$k]}" && break
    done
    if [ -z "$cputemp" ]; then
      for k in "${!S[@]}"; do
        case "$k" in
          temperature_*k10temp*|temperature_*coretemp*|temperature_*Tctl*)
            [ "${k%"#unit"}" = "$k" ] && cputemp="${S[$k]}" && break ;;
        esac
      done
    fi
    [ -z "$cputemp" ] && cputemp=$(cpu_temp_from_hwmon)
  fi

  # ---- GPU utilization (amdgpu iGPU, same die as CPU) -------------------
  gpuutil=""
  for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -f "$f" ] && gpuutil=$(cat "$f" 2>/dev/null) && break
  done

  # ---- network history ring buffers -------------------------------------
  UP_HIST+=( "$(to_bps "${S[network_${NETIF}_upload_speed]}")" )
  DOWN_HIST+=( "$(to_bps "${S[network_${NETIF}_download_speed]}")" )
  (( ${#UP_HIST[@]} > MAX_SAMPLES )) && UP_HIST=("${UP_HIST[@]:1}")
  (( ${#DOWN_HIST[@]} > MAX_SAMPLES )) && DOWN_HIST=("${DOWN_HIST[@]:1}")

  # ---- disks: temperatures from emhttp (never wakes disks) --------------
  hdd_max=0 ssd_max=0 hdd_n=0 ssd_n=0 standby=0 hot_list=""
  if [ -f "$DISKS_INI" ]; then
    dname="" dev="" temp=""
    flush_disk() {
      [ -z "$dev" ] && return
      case "$dname" in flash|"") dev=""; return ;; esac
      if [ "$temp" = "*" ] || [ -z "$temp" ]; then
        standby=$((standby + 1)); dev=""; return
      fi
      local is_ssd=0 limit
      case "$dev" in nvme*) is_ssd=1 ;; *)
        [ "$(cat /sys/block/$dev/queue/rotational 2>/dev/null)" = "0" ] && is_ssd=1 ;;
      esac
      if [ "$is_ssd" = "1" ]; then
        ssd_n=$((ssd_n + 1)); [ "$temp" -gt "$ssd_max" ] && ssd_max=$temp
        limit=$SSD_HOT
      else
        hdd_n=$((hdd_n + 1)); [ "$temp" -gt "$hdd_max" ] && hdd_max=$temp
        limit=$HDD_HOT
      fi
      if [ "$temp" -ge "$limit" ] 2>/dev/null; then
        hot_list="$hot_list, $dname ${temp}°C"
      fi
      dev=""
    }
    while IFS= read -r line; do
      case "$line" in
        \[*\])   flush_disk; dname="${line#[\"}"; dname="${dname%\"]}"
                 dname="${dname#[}"; dname="${dname%]}"; dev=""; temp="" ;;
        device=*) dev="${line#device=}"; dev="${dev//\"/}" ;;
        temp=*)   temp="${line#temp=}"; temp="${temp//\"/}" ;;
      esac
    done < "$DISKS_INI"
    flush_disk
  fi
  hot_list="${hot_list#, }"

  # ---- write panel sensor file ------------------------------------------
  {
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
    slot gpu_util "${gpuutil%%.*}" "$UTIL_WARN" "$UTIL_HOT" "%"
    slot cpu_temp "${cputemp%%.*}" "$CPU_TEMP_WARN" "$CPU_TEMP_HOT" "°C"
    echo "mem_pct: ${S[mem_usage_percent]%%.*}%"

    # always write every key so a NETIF change can never leave stale values
    # (speed values already contain their unit, e.g. "13.84 KB/s")
    u="network_${NETIF}_upload_speed"
    d="network_${NETIF}_download_speed"
    echo "net_up: ${S[$u]}"
    echo "net_down: ${S[$d]}"
    ip="${S[network_${NETIF}_address0]}"
    echo "net_ip: ${ip%/*}"

    sparkline UP_HIST
    echo "net_up_graph: $SPARK"
    echo "net_up_peak: $(humanize "$PEAK") peak"
    sparkline DOWN_HIST
    echo "net_down_graph: $SPARK"
    echo "net_down_peak: $(humanize "$PEAK") peak"
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
  } > "$TMP"
  mv -f "$TMP" "$OUT"

  sleep "$REFRESH"
done
