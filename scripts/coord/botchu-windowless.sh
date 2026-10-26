#!/bin/bash
# Stay in the ancestry of this BotChu-only build/Core/orchestration process, so busy.sh can
# distinguish it from window tests and from the other repositories using the same gate.
set -euo pipefail
export BOTCHU_WINDOWLESS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$@"
