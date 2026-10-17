#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-bedrock-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/PhoneAgent/Services/BedrockClient.swift" \
  "$project_dir/Tests/Bedrock/main.swift" \
  -o "$check_dir/phone-bedrock-checks"
"$check_dir/phone-bedrock-checks"
