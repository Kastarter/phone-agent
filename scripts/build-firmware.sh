#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 || "${1:-esp32s3}" != "esp32s3" ]]; then
  echo "Usage: bash scripts/build-firmware.sh [esp32s3]" >&2
  exit 2
fi
if command -v idf.py >/dev/null 2>&1; then
  idf_command=(idf.py)
elif [[ -n "${IDF_PATH:-}" && -f "$IDF_PATH/tools/idf.py" ]]; then
  # EIM may expose idf.py only as a shell function, which child scripts cannot see.
  idf_command=(python "$IDF_PATH/tools/idf.py")
else
  echo "Enable your ESP-IDF 5.5.4 environment before running this script." >&2
  exit 1
fi
target="esp32s3"
cd "$project_dir/firmware"
idf_args=(-B "build-$target" -D "SDKCONFIG=sdkconfig.$target" -D "SDKCONFIG_DEFAULTS=sdkconfig.defaults")
if [[ ! -f "sdkconfig.$target" ]]; then
  "${idf_command[@]}" "${idf_args[@]}" set-target "$target"
fi
"${idf_command[@]}" "${idf_args[@]}" build
