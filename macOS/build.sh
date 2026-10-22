#!/usr/bin/env bash
# Build and sign BotChu.app into the folder given (default: macOS/build/, which is gitignored).
set -eo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${1:-$dir/build}"
out="$(cd "${1:-$dir/build}" && pwd)/BotChu.app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

swift build -c release --package-path "$dir" --product BotChu 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' || true; }
bin="$(swift build -c release --package-path "$dir" --show-bin-path)/BotChu"
[ -x "$bin" ] || { echo "build: swift build did not produce $bin" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
# SwiftPM's default build system records the deployment target as the binary's SDK version as well
# (sdk 14.0), so macOS runs the app in compatibility mode, with the old window chrome, in which the
# toolbar overhangs the sidebar. Record the SDK the app was actually linked against.
minos=$(vtool -show-build "$bin" | awk '$1 == "minos" { print $2 }')
vtool -set-build-version macos "$minos" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$out/Contents/MacOS/BotChu" "$bin"

# The icon is drawn in code (icon.swift) rather than committed as a binary.
swiftc "$dir/icon.swift" -o "$tmp/icon"
"$tmp/icon" "$tmp/AppIcon.iconset"
iconutil -c icns "$tmp/AppIcon.iconset" -o "$out/Contents/Resources/AppIcon.icns"

cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.BotChu</string>
  <key>CFBundleExecutable</key><string>BotChu</string>
  <key>CFBundleName</key><string>BotChu</string>
  <key>CFBundleDisplayName</key><string>BotChu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$(git -C "$dir" rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A stable identity keeps macOS permission and Keychain grants across rebuilds; ad hoc without one.
codesign -fs "Apple Development" "$out" 2>/dev/null || codesign -fs - "$out"
echo "build: $out"
