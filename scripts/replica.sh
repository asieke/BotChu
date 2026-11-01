#!/usr/bin/env bash
# The replica of the owner's BotChu data the replica journeys run on (#422; README.md, Operate):
#   scripts/replica.sh refresh   rebuild it from the live data, which it only reads
#   scripts/replica.sh status    when it was refreshed, and its totals
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/replica.py" "$@"
