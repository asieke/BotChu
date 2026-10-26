#!/bin/bash
# Atomic replacements preserve active runs and the shared gate's lock/run paths.
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
destination=${1:-/tmp/botchu-coord}
mkdir -p "$destination"
for name in busy.py busy.sh gate.sh; do
  if ! cmp -s "$source_dir/$name" "$destination/$name"; then
    temporary=$(mktemp "$destination/.$name.XXXXXX")
    cp "$source_dir/$name" "$temporary"
    chmod +x "$temporary"
    mv -f "$temporary" "$destination/$name"
  fi
done
