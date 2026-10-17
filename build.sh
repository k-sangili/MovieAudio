#!/bin/zsh
# Builds MovieAudio.app into ./build. Pass --install to copy it into /Applications.
set -euo pipefail
cd "${0:A:h}"

APP=build/MovieAudio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Regenerate the icon with: swift Icon/make_icon.swift Icon/icon_1024.png (then rebuild AppIcon.icns)
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/MovieAudio"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Movie Audio</string>
  <key>CFBundleDisplayName</key><string>Movie Audio</string>
  <key>CFBundleIdentifier</key><string>com.kameshsangili.MovieAudio</string>
  <key>CFBundleExecutable</key><string>MovieAudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/MovieAudio.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/MovieAudio.app"
fi
