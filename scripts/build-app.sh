#!/bin/bash

set -euo pipefail

configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
app_bundle="$package_dir/dist/Pinch.app"
contents_dir="$app_bundle/Contents"

swift build --package-path "$package_dir" --configuration "$configuration" --product Pinch
binary_dir="$(swift build --package-path "$package_dir" --configuration "$configuration" --show-bin-path)"

rm -rf "$app_bundle"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_dir/Pinch" "$contents_dir/MacOS/Pinch"
cp "$package_dir/Resources/Info.plist" "$contents_dir/Info.plist"

# Compile the Icon Composer document the way Xcode does: Assets.car carries the Liquid Glass
# icon, and actool also writes AppIcon.icns for older consumers such as Finder previews.
xcrun actool "$package_dir/Resources/AppIcon.icon" \
  --compile "$contents_dir/Resources" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$package_dir/.build/AppIcon-partial.plist" \
  --output-format human-readable-text \
  >/dev/null

/usr/bin/codesign --force --sign - "$app_bundle"
echo "$app_bundle"
