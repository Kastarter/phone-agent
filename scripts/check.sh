#!/usr/bin/env bash
# Offline checks: protocol, product state, Bedrock signing and the Fast agent. With a built app, also checks
# that the bundle holds the Live Activity extension and no example config.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "Usage: bash scripts/check.sh [path/to/PhoneAgent.app]" >&2
  exit 2
fi
bash "$project_dir/Tests/run.sh"
bash "$project_dir/Tests/ProductState/run.sh"
bash "$project_dir/Tests/Bedrock/run.sh"
bash "$project_dir/Tests/Brain/run.sh"
if [[ $# -eq 1 ]]; then
  app="$1"
  [[ -f "$app/Info.plist" ]] || { echo "No built app at $app" >&2; exit 1; }
  [[ -d "$app/PlugIns/PhoneAgentActivity.appex" ]] || { echo "The Live Activity extension is missing from $app" >&2; exit 1; }
  [[ ! -e "$app/VoiceAgent.example.json" ]] || { echo "VoiceAgent.example.json must not be bundled" >&2; exit 1; }
  echo "PASS: built app bundle"
fi
