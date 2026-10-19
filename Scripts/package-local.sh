#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 2
fi

cd "$project_root"
swift build -c "$configuration" -j 8
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
destination="$project_root/dist/ProxyLab.app"
staging="$project_root/dist/dmg-staging"
mkdir -p "$project_root/dist"
rm -rf "$destination" "$staging"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources" "$staging"
if [[ "$configuration" == "release" ]]; then
  swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64 -j 8
  intel_directory="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64 --show-bin-path)"
  lipo -create "$binary_directory/ProxyLab" "$intel_directory/ProxyLab" -output "$destination/Contents/MacOS/ProxyLab"
else
  cp "$binary_directory/ProxyLab" "$destination/Contents/MacOS/ProxyLab"
fi

for resource in "$binary_directory"/*.bundle; do
  if [[ -d "$resource" ]]; then cp -R "$resource" "$destination/Contents/Resources/"; fi
done

cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>ProxyLab</string>
  <key>CFBundleExecutable</key><string>ProxyLab</string>
  <key>CFBundleIdentifier</key><string>dev.proxylab.local</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ProxyLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST

plutil -lint "$destination/Contents/Info.plist"
codesign --force --deep --sign - "$destination"
codesign --verify --deep --strict "$destination"
cp -R "$destination" "$staging/ProxyLab.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname ProxyLab -srcfolder "$staging" -ov -format UDZO "$project_root/dist/ProxyLab.dmg" >/dev/null
rm -rf "$staging"
echo "Created $destination"
echo "Created $project_root/dist/ProxyLab.dmg"
