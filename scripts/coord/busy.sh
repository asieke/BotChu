#!/bin/bash
# Keep the shared gate's process policy, except for BotChu's explicit windowless wrapper.
exec python3 "$(dirname "$0")/busy.py" "$@"
