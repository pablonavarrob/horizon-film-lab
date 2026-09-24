#!/bin/bash
# SwiftUI needs a real bundle: without an Info.plist the process runs but never
# gets a window. Builds Horizon.app around the SPM binary.
set -e
cd "$(dirname "$0")"
swift build -c release

# Regenerate the icon set. The badge fills 100% of the canvas width (it is
# 1.27:1, so a square icon must letterbox it vertically -- that IS maximal).
# The 1024px slot is dropped: it was 862KB of the 1.9MB icns and nothing here
# renders the icon above 512px.
if [ Resources/icon-1024.png -nt Resources/AppIcon.icns ]; then
  rm -rf /tmp/AppIcon.iconset && mkdir -p /tmp/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-1024.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    d=$((s*2))
    [ $d -le 512 ] && sips -z $d $d Resources/icon-1024.png \
      --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
fi
APP="Horizon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/horizon "$APP/Contents/MacOS/Horizon"
cp Resources/logo.png Resources/AppIcon.icns "$APP/Contents/Resources/"
# Extra print LUTs are optional; the built-in RA-4 model needs no LUT files.
if [ -d Resources/luts ]; then
  cp -R Resources/luts "$APP/Contents/Resources/"
else
  echo "Resources/luts not found; building with the built-in print model only."
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Horizon</string>
  <key>CFBundleDisplayName</key><string>Horizon</string>
  <key>CFBundleExecutable</key><string>Horizon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.horizon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
echo "built $PWD/$APP"
