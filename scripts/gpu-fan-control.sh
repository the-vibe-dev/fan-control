#!/usr/bin/env bash
set -euo pipefail

# GPU-aware Dell/PowerEdge fan control for Proxmox.
# Reads GPU temp exported by a VM/render node and adjusts server chassis fans.

BRIDGE_DIR="${BRIDGE_DIR:-/mnt/nas_ai/shared/gpu_fan_bridge}"
TEMP_FILE="$BRIDGE_DIR/gpu_temp"
HEARTBEAT_FILE="$BRIDGE_DIR/heartbeat"
STATUS_FILE="$BRIDGE_DIR/status"

STATE_FILE="${STATE_FILE:-/run/gpu-fan-state}"
LOG_FILE="${LOG_FILE:-/var/log/gpu-fan-control.log}"

HEARTBEAT_WARN_AGE="${HEARTBEAT_WARN_AGE:-90}"
HEARTBEAT_FAILSAFE_AGE="${HEARTBEAT_FAILSAFE_AGE:-240}"
MIN_HOLD_SECONDS="${MIN_HOLD_SECONDS:-30}"

log() {
  echo "$(date '+%F %T') $*" >> "$LOG_FILE"
}

set_manual() {
  ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null
}

set_fan_hex() {
  local hex="$1"
  set_manual
  ipmitool raw 0x30 0x30 0x02 0xff "$hex" >/dev/null
}

level_to_hex() {
  case "$1" in
    0) echo "0x20" ;; # 32%
    1) echo "0x28" ;; # 40%
    2) echo "0x32" ;; # 50%
    3) echo "0x3c" ;; # 60%
    4) echo "0x50" ;; # 80%
    5) echo "0x64" ;; # 100%
    *) echo "0x64" ;;
  esac
}

level_to_label() {
  case "$1" in
    0) echo "32%" ;;
    1) echo "40%" ;;
    2) echo "50%" ;;
    3) echo "60%" ;;
    4) echo "80%" ;;
    5) echo "100%" ;;
    *) echo "100%" ;;
  esac
}

get_state_value() {
  local key="$1"
  local default="$2"

  if [[ -f "$STATE_FILE" ]]; then
    local val
    val="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi

  echo "$default"
}

write_state() {
  local level="$1"
  local temp="$2"
  local now
  now="$(date +%s)"
  printf 'LEVEL=%s\nLAST_CHANGE=%s\nLAST_TEMP=%s\n' "$level" "$now" "$temp" > "$STATE_FILE"
}

hold_previous_or_failsafe() {
  local reason="$1"
  local current_level
  current_level="$(get_state_value LEVEL 4)"

  if [[ "$current_level" =~ ^[0-5]$ ]]; then
    set_fan_hex "$(level_to_hex "$current_level")"
    log "$reason; holding previous level=$current_level ($(level_to_label "$current_level"))"
    exit 0
  fi

  set_fan_hex "0x64"
  write_state 5 "unknown"
  log "$reason; no previous state, failsafe 100%"
  exit 1
}

failsafe_max() {
  local reason="$1"
  set_fan_hex "0x64"
  write_state 5 "unknown"
  log "$reason; failsafe 100%"
  exit 1
}

if [[ ! -d "$BRIDGE_DIR" ]]; then
  failsafe_max "bridge dir missing: $BRIDGE_DIR"
fi

if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  hold_previous_or_failsafe "heartbeat missing"
fi

NOW="$(date +%s)"
HB="$(tr -d '[:space:]' < "$HEARTBEAT_FILE" 2>/dev/null || true)"

if ! [[ "$HB" =~ ^[0-9]+$ ]]; then
  hold_previous_or_failsafe "invalid heartbeat '$HB'"
fi

AGE=$((NOW - HB))

if (( AGE > HEARTBEAT_FAILSAFE_AGE )); then
  failsafe_max "heartbeat stale ${AGE}s"
elif (( AGE > HEARTBEAT_WARN_AGE )); then
  hold_previous_or_failsafe "heartbeat old ${AGE}s"
fi

if [[ ! -f "$TEMP_FILE" ]]; then
  hold_previous_or_failsafe "temp file missing"
fi

TEMP="$(tr -d '[:space:]' < "$TEMP_FILE" 2>/dev/null || true)"

if ! [[ "$TEMP" =~ ^[0-9]+$ ]]; then
  hold_previous_or_failsafe "invalid temp '$TEMP'"
fi

if (( TEMP < 20 || TEMP > 110 )); then
  failsafe_max "out of range temp '$TEMP'"
fi

CURRENT_LEVEL="$(get_state_value LEVEL 0)"
LAST_CHANGE="$(get_state_value LAST_CHANGE 0)"

[[ "$CURRENT_LEVEL" =~ ^[0-5]$ ]] || CURRENT_LEVEL=0
[[ "$LAST_CHANGE" =~ ^[0-9]+$ ]] || LAST_CHANGE=0

SECONDS_SINCE_CHANGE=$((NOW - LAST_CHANGE))
TARGET_LEVEL="$CURRENT_LEVEL"

# Rise thresholds:
#   65C -> 40%
#   72C -> 50%
#   78C -> 60%
#   84C -> 80%
#   88C -> 100%
# Drop thresholds are lower than rise thresholds to prevent fan bounce.
case "$CURRENT_LEVEL" in
  0)
    if   (( TEMP >= 88 )); then TARGET_LEVEL=5
    elif (( TEMP >= 84 )); then TARGET_LEVEL=4
    elif (( TEMP >= 78 )); then TARGET_LEVEL=3
    elif (( TEMP >= 72 )); then TARGET_LEVEL=2
    elif (( TEMP >= 65 )); then TARGET_LEVEL=1
    else TARGET_LEVEL=0
    fi
    ;;
  1)
    if   (( TEMP >= 88 )); then TARGET_LEVEL=5
    elif (( TEMP >= 84 )); then TARGET_LEVEL=4
    elif (( TEMP >= 78 )); then TARGET_LEVEL=3
    elif (( TEMP >= 72 )); then TARGET_LEVEL=2
    elif (( TEMP < 62 )); then TARGET_LEVEL=0
    else TARGET_LEVEL=1
    fi
    ;;
  2)
    if   (( TEMP >= 88 )); then TARGET_LEVEL=5
    elif (( TEMP >= 84 )); then TARGET_LEVEL=4
    elif (( TEMP >= 78 )); then TARGET_LEVEL=3
    elif (( TEMP < 68 )); then TARGET_LEVEL=1
    else TARGET_LEVEL=2
    fi
    ;;
  3)
    if   (( TEMP >= 88 )); then TARGET_LEVEL=5
    elif (( TEMP >= 84 )); then TARGET_LEVEL=4
    elif (( TEMP < 74 )); then TARGET_LEVEL=2
    else TARGET_LEVEL=3
    fi
    ;;
  4)
    if   (( TEMP >= 88 )); then TARGET_LEVEL=5
    elif (( TEMP < 80 )); then TARGET_LEVEL=3
    else TARGET_LEVEL=4
    fi
    ;;
  5)
    if (( TEMP < 85 )); then TARGET_LEVEL=4
    else TARGET_LEVEL=5
    fi
    ;;
esac

# Do not rapidly decrease fan speed.
if (( TARGET_LEVEL < CURRENT_LEVEL )) && (( SECONDS_SINCE_CHANGE < MIN_HOLD_SECONDS )); then
  TARGET_LEVEL="$CURRENT_LEVEL"
fi

# Limit normal changes to one fan level at a time.
if (( TEMP >= 92 )); then
  TARGET_LEVEL=5
else
  if (( TARGET_LEVEL > CURRENT_LEVEL + 1 )); then
    TARGET_LEVEL=$((CURRENT_LEVEL + 1))
  elif (( TARGET_LEVEL < CURRENT_LEVEL - 1 )); then
    TARGET_LEVEL=$((CURRENT_LEVEL - 1))
  fi
fi

if (( TARGET_LEVEL != CURRENT_LEVEL )); then
  FAN_HEX="$(level_to_hex "$TARGET_LEVEL")"
  FAN_LABEL="$(level_to_label "$TARGET_LEVEL")"
  set_fan_hex "$FAN_HEX"
  write_state "$TARGET_LEVEL" "$TEMP"
  log "temp=${TEMP}C age=${AGE}s current=${CURRENT_LEVEL} target=${TARGET_LEVEL} applied=${FAN_LABEL}"
else
  printf 'LEVEL=%s\nLAST_CHANGE=%s\nLAST_TEMP=%s\n' "$CURRENT_LEVEL" "$LAST_CHANGE" "$TEMP" > "$STATE_FILE"
  log "temp=${TEMP}C age=${AGE}s holding level=${CURRENT_LEVEL} ($(level_to_label "$CURRENT_LEVEL"))"
fi

exit 0
