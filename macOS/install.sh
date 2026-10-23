#!/bin/sh
# Build BotChu into ~/Applications and smoke-test that it launches. BotChu is a windowed app you open
# when you want it, so it has no LaunchAgent; a copy that was running is restarted on the new build
# (which stops any bot mid-turn). Only the installed copy counts: review copies (ui-review.sh) and
# builds run from a checkout are also called BotChu, and are neither restarted nor quit.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HOME/Applications"
# The real path, which macOS starts the app from and ps reports.
app="$(cd "$HOME/Applications" && pwd -P)/BotChu.app"

# The installed copy's processes: those whose executable is this bundle's.
installed() {
  ps -ax -ww -o pid=,comm= | awk -v exe="$app/Contents/MacOS/BotChu" '{ pid = $1; sub(/^ *[0-9]+ +/, "") } $0 == exe { print pid }'
}

was_running=false
if [ -n "$(installed)" ]; then
  was_running=true
  kill $(installed) 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(installed)" ] && break; sleep 0.5; done
fi

"$dir/build.sh" "$HOME/Applications"
codesign --verify --strict "$app"

# Smoke test: the app starts. Without a window open beforehand, launch it hidden and quit it again.
if [ "$was_running" = true ]; then open -g "$app"; else open -gj "$app"; fi
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(installed)" ] && break; sleep 0.5; done
[ -n "$(installed)" ] || { echo "install: BotChu did not start" >&2; exit 1; }
if [ "$was_running" = true ]; then
  echo "install: BotChu restarted from $app"
else
  kill $(installed) 2>/dev/null || true
  echo "install: BotChu installed at $app"
fi
