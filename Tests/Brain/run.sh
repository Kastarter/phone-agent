#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-brain-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/PhoneAgent/Brain/JSON.swift" \
  "$project_dir/PhoneAgent/Brain/BrainPorts.swift" \
  "$project_dir/PhoneAgent/Brain/BrainActions.swift" \
  "$project_dir/PhoneAgent/Brain/ProbeFit.swift" \
  "$project_dir/PhoneAgent/Brain/BrainCommand.swift" \
  "$project_dir/PhoneAgent/Brain/FrameVision.swift" \
  "$project_dir/PhoneAgent/Brain/BrainMapping.swift" \
  "$project_dir/PhoneAgent/Brain/BrainTrace.swift" \
  "$project_dir/PhoneAgent/Brain/AppLauncher.swift" \
  "$project_dir/PhoneAgent/Brain/ScreenReader.swift" \
  "$project_dir/PhoneAgent/Services/KeyboardLayouts.swift" \
  "$project_dir/PhoneAgent/Brain/BrainFastPaths.swift" \
  "$project_dir/PhoneAgent/Brain/AssistiveTouchSpots.swift" \
  "$project_dir/PhoneAgent/Brain/BrainPrompts.swift" \
  "$project_dir/PhoneAgent/Brain/BrainBrief.swift" \
  "$project_dir/Tests/Brain/main.swift" \
  -o "$check_dir/phone-brain-checks"
"$check_dir/phone-brain-checks"
