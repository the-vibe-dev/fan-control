#!/usr/bin/env bash
set -euo pipefail

# GPU temperature exporter for the GPU VM/render node.
# Writes the hottest NVIDIA GPU temp to a shared folder that the Proxmox host can read.

OUT_DIR="${OUT_DIR:-/mnt/nas_ai/shared/gpu_fan_bridge}"
TEMP_FILE="$OUT_DIR/gpu_temp"
DETAIL_FILE="$OUT_DIR/gpu_temps_detail"
HEARTBEAT_FILE="$OUT_DIR/heartbeat"
STATUS_FILE="$OUT_DIR/status"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"

mkdir -p "$OUT_DIR"

while true; do
  NOW="$(date +%s)"

  TEMPS_RAW="$(nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)"

  if [[ -n "$TEMPS_RAW" ]]; then
    MAX_TEMP="$(echo "$TEMPS_RAW" \
      | awk -F',' '{gsub(/ /,"",$2); print $2}' \
      | grep -E '^[0-9]+$' \
      | sort -nr \
      | head -n1 || true)"

    if [[ "$MAX_TEMP" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$MAX_TEMP" > "$TEMP_FILE"
      printf '%s\n' "$TEMPS_RAW" > "$DETAIL_FILE"
      printf '%s\n' "$NOW" > "$HEARTBEAT_FILE"
      printf 'ok max_temp=%s timestamp=%s\n' "$MAX_TEMP" "$NOW" > "$STATUS_FILE"
      echo "ok max_temp=$MAX_TEMP temps=[$TEMPS_RAW]"
    else
      printf 'bad_parse timestamp=%s raw=[%s]\n' "$NOW" "$TEMPS_RAW" > "$STATUS_FILE"
      echo "bad_parse raw=[$TEMPS_RAW]" >&2
    fi
  else
    # Do not refresh heartbeat on nvidia-smi failure.
    # The Proxmox host should treat a stale heartbeat as unsafe.
    printf 'nvidia_smi_failed timestamp=%s\n' "$NOW" > "$STATUS_FILE"
    echo "nvidia-smi failed; not updating heartbeat" >&2
  fi

  sleep "$INTERVAL_SECONDS"
done
