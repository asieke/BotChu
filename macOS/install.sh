#!/bin/sh
# Build BotChu into ~/Applications and smoke-test that it launches. BotChu is a windowed app you open
# when you want it, so it has no LaunchAgent; a copy that was running is restarted on the new build
# (which stops any bot mid-turn).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
app="$HOME/Applications/BotChu.app"

was_running=false
if pgrep -x BotChu >/dev/null; then
  was_running=true
  pkill -x BotChu
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x BotChu >/dev/null || break; sleep 0.5; done
fi

mkdir -p "$HOME/Applications"
"$dir/build.sh" "$HOME/Applications"
codesign --verify --strict "$app"

# Smoke test: the app starts. Without a window open beforehand, launch it hidden and quit it again.
if [ "$was_running" = true ]; then open -g "$app"; else open -gj "$app"; fi
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x BotChu >/dev/null && break; sleep 0.5; done
pgrep -x BotChu >/dev/null || { echo "install: BotChu did not start" >&2; exit 1; }
if [ "$was_running" = true ]; then
  echo "install: BotChu restarted from $app"
else
  pkill -x BotChu
  echo "install: BotChu installed at $app"
fi
