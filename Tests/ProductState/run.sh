#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/phone-product-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

# Keep the production engine intact except for the platform import; Environment.swift supplies the app's
# UIKit, capture, BLE, pointer, screen and model adapters as offline fakes.
python3 - "$project_dir/PhoneAgent/Services/AgentEngine.swift" "$check_dir/Engine.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('import UIKit') == 1
Path(sys.argv[2]).write_text(source.replace('import UIKit', 'import CoreGraphics'))
PY
brain="$project_dir/PhoneAgent/Brain"
xcrun swiftc -module-cache-path "$check_dir/module-cache" -parse-as-library \
  "$project_dir/Shared/AgentModels.swift" \
  "$project_dir/Shared/MouseProtocol.swift" \
  "$project_dir/Shared/VoiceCommand.swift" \
  "$project_dir/PhoneAgent/Stores/TaskHistoryStore.swift" \
  "$project_dir/PhoneAgent/Services/PrivacyConsent.swift" \
  "$project_dir/PhoneAgent/Services/KeyboardLayouts.swift" \
  "$brain/JSON.swift" "$brain/BrainPorts.swift" "$brain/BrainActions.swift" "$brain/BrainMapping.swift" \
  "$brain/BrainCommand.swift" "$brain/BrainTrace.swift" "$brain/FrameVision.swift" "$brain/BrainBrief.swift" \
  "$brain/BrainPrompts.swift" "$brain/BrainContext.swift" "$brain/BrainFastPaths.swift" "$brain/AppLauncher.swift" \
  "$brain/ScreenReader.swift" "$brain/AssistiveTouchSpots.swift" "$brain/FastAgent.swift" \
  "$project_dir/Tests/ProductState/ContextChecks.swift" \
  "$project_dir/Tests/ProductState/Environment.swift" \
  "$check_dir/Engine.swift" \
  "$project_dir/Tests/ProductState/main.swift" \
  -o "$check_dir/phone-product-checks"
"$check_dir/phone-product-checks"
