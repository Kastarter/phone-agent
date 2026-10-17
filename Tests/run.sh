#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-protocol-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/PhoneAgent/Services/HIDKeyboard.swift" \
  "$project_dir/PhoneAgent/Services/KeyboardLayouts.swift" \
  "$project_dir/Tests/main.swift" \
  -o "$check_dir/protocol-checks"
"$check_dir/protocol-checks"
