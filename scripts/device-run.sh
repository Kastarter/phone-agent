#!/usr/bin/env bash
# Drive a Debug build of Phone Agent on a real iPhone through phoneagent://run links and report each run.
# Usage: scripts/device-run.sh "<task>" [--device UDID] [--bundle ID] [--repeat N] [--timeout S]
# The device and bundle id come from the flags or PHONE_AGENT_DEVICE / PHONE_AGENT_BUNDLE (the PA_BUNDLE_ID in
# Config/Local.xcconfig). Phone Agent must already be sharing the full screen with the mouse calibrated; the app
# is not terminated between runs because that would end screen sharing.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle="${PHONE_AGENT_BUNDLE:-}"
device="${PHONE_AGENT_DEVICE:-}"
repeat=1
timeout=180
task=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --repeat) repeat="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) sed -n 2,6p "$0"; exit 0 ;;
    *) if [[ -z "$task" ]]; then task="$1"; shift; else echo "Unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done
[[ -n "$task" ]] || { echo "Usage: scripts/device-run.sh \"<task>\" [--device UDID] [--bundle ID] [--repeat N] [--timeout S]" >&2; exit 2; }
[[ -n "$device" ]] || { echo "Set PHONE_AGENT_DEVICE or pass --device (the UDID from: xcrun devicectl list devices)" >&2; exit 2; }
[[ -n "$bundle" ]] || { echo "Set PHONE_AGENT_BUNDLE or pass --bundle (the PA_BUNDLE_ID from Config/Local.xcconfig)" >&2; exit 2; }
[[ "$repeat" =~ ^[0-9]+$ && "$repeat" -ge 1 ]] || { echo "--repeat must be a positive integer" >&2; exit 2; }
[[ "$timeout" =~ ^[0-9]+$ && "$timeout" -ge 1 ]] || { echo "--timeout must be a positive integer" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/device-run.XXXXXX")"
trap 'rm -rf "$work"' EXIT
encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$task")"

fetch() {  # fetch <Documents/name> <local path>
  xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
    --domain-identifier "$bundle" --source "$1" --destination "$2" -q >/dev/null 2>&1
}

ids=()
missed=()
for ((i = 1; i <= repeat; i++)); do
  id="dr-$(date +%Y%m%d%H%M%S)-$i-$RANDOM"
  echo "[$i/$repeat] $id: $task"
  xcrun devicectl device process launch --device "$device" -q \
    --payload-url "phoneagent://run?task=$encoded&id=$id" "$bundle" >/dev/null
  deadline=$((SECONDS + timeout)); found=0
  while ((SECONDS < deadline)); do
    sleep 2
    if fetch Documents/device-runs.jsonl "$work/device-runs.jsonl" && grep -q "\"id\":\"$id\"" "$work/device-runs.jsonl"; then
      found=1; break
    fi
  done
  if ((found == 0)); then
    missed+=("$id")
    echo "  timed out after ${timeout}s; stopping the task"
    xcrun devicectl device process launch --device "$device" -q --payload-url "phoneagent://stop" "$bundle" >/dev/null || true
    sleep 3
  else
    ids+=("$id")
    grep "\"id\":\"$id\"" "$work/device-runs.jsonl" | python3 -c 'import json, sys; r = json.loads(sys.stdin.readline()); print("  %s in %.1f s: %s" % (r["outcome"], r["seconds"], r["summary"]))'
  fi
done

fetch Documents/device-runs.jsonl "$work/device-runs.jsonl" || true
fetch Documents/fast-agent-trace.log "$work/fast-agent-trace.log" || : > "$work/fast-agent-trace.log"
echo
if ((${#ids[@]} > 0)); then
  python3 "$script_dir/trace-report.py" "$work/device-runs.jsonl" "$work/fast-agent-trace.log" "${ids[@]}"
fi
if ((${#missed[@]} > 0)); then
  echo "Timed out without a result: ${missed[*]}"
  exit 1
fi
