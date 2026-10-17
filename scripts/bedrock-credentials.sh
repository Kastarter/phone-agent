#!/usr/bin/env bash
# Mint 12-hour AWS STS credentials for the app's Bedrock provider and copy them to the
# clipboard. With Universal Clipboard (same Apple ID, Bluetooth + Wi-Fi on), paste them on
# the iPhone into Settings > Model connection > AWS Bedrock > credentials field.
#
# The long-term IAM key stays on the Mac; the phone only ever holds the temporary token.
#
# Usage: bash scripts/bedrock-credentials.sh <env-file> [hours]
# The env file sets AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (and optionally AWS_REGION) for an IAM user
# allowed to call Bedrock. Keep it outside the repository.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash scripts/bedrock-credentials.sh <env-file-with-AWS_ACCESS_KEY_ID> [hours]" >&2
  exit 2
fi
env_file="$1"
hours="${2:-12}"
if [[ ! -f "$env_file" ]]; then
  echo "Credential env file not found: $env_file" >&2
  exit 1
fi
creds="$(
  set -a; . "$env_file" >/dev/null 2>&1; set +a
  unset AWS_PROFILE AWS_SESSION_TOKEN
  aws sts get-session-token --duration-seconds $((hours * 3600)) --query Credentials --output json
)"
printf '%s' "$creds" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),separators=(",",":")),end="")' | pbcopy
expiry="$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Expiration"])')"
echo "Copied Bedrock credentials to the clipboard (expire $expiry)."
echo "On the iPhone: Settings > Model connection > AWS Bedrock > paste into the credentials field > Save > Test connection."
