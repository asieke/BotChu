#!/usr/bin/env bash
# Build and sign BotChu.app into the folder given (default: macOS/build/, which is gitignored).
set -eo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${1:-$dir/build}"
out="$(cd "${1:-$dir/build}" && pwd)/BotChu.app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Debug --build-tests also invalidates optimized Core in a shared Xcode build manifest.
# Keep the app independent of both test configurations, including when locating its binary.
app_scratch="$dir/.build/app"
swift build -c release --package-path "$dir" --scratch-path "$app_scratch" --product BotChu 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' || true; }
bin="$(swift build -c release --package-path "$dir" --scratch-path "$app_scratch" --show-bin-path)/BotChu"
[ -x "$bin" ] || { echo "build: swift build did not produce $bin" >&2; exit 1; }
# The Sail account's headless agent, which the app runs from beside itself (README.md, Sail).
swift build -c release --package-path "$dir" --scratch-path "$app_scratch" --product botchu-sail 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' || true; }
sail_helper="$(dirname "$bin")/botchu-sail"
[ -x "$sail_helper" ] || { echo "build: swift build did not produce $sail_helper" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
# SwiftPM's default build system records the deployment target as the binary's SDK version as well
# (sdk 14.0), so macOS runs the app in compatibility mode, with the old window chrome, in which the
# toolbar overhangs the sidebar. Record the SDK the app was actually linked against.
minos=$(vtool -show-build "$bin" | awk '$1 == "minos" { print $2 }')
vtool -set-build-version macos "$minos" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$out/Contents/MacOS/BotChu" "$bin"
cp "$sail_helper" "$out/Contents/MacOS/botchu-sail"

# SwiftPM's bundled, offline chat renderers must travel with the installed app.
cp -R "$(dirname "$bin")/BotChu_BotChu.bundle" "$out/Contents/Resources/"

# The icon is drawn in code (icon.swift) rather than committed as a binary.
swiftc "$dir/icon.swift" -o "$tmp/icon"
"$tmp/icon" "$tmp/AppIcon.iconset"
iconutil -c icns "$tmp/AppIcon.iconset" -o "$out/Contents/Resources/AppIcon.icns"

# The commit it is built from (-dirty with uncommitted changes), which reports filed from it name.
commit=$(git -C "$dir" rev-parse --short=7 HEAD 2>/dev/null || true)
if [ -n "$commit" ] && ! git -C "$dir" diff --quiet HEAD -- 2>/dev/null; then commit="$commit-dirty"; fi

cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.BotChu</string>
  <key>CFBundleExecutable</key><string>BotChu</string>
  <key>CFBundleName</key><string>BotChu</string>
  <key>CFBundleDisplayName</key><string>BotChu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$(tr -d '[:space:]' < "$dir/VERSION")</string>
  <key>CFBundleVersion</key><string>$(git -C "$dir" rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>BotChuCommit</key><string>$commit</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.BotChu.bot</string>
    <key>UTTypeDescription</key><string>BotChu bot</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict><dict>
    <key>UTTypeIdentifier</key><string>local.BotChu.area</string>
    <key>UTTypeDescription</key><string>BotChu Project Area</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
</dict></plist>
PLIST
# A stable identity keeps macOS permission and Keychain grants across rebuilds; ad hoc without one.
# The helper is nested code, signed first.
codesign -fs "Apple Development" "$out/Contents/MacOS/botchu-sail" 2>/dev/null || codesign -fs - "$out/Contents/MacOS/botchu-sail"
codesign -fs "Apple Development" "$out" 2>/dev/null || codesign -fs - "$out"
echo "build: $out"
