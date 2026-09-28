#!/bin/bash
# SwiftUI needs a real bundle: without an Info.plist the process runs but never
# gets a window. Builds Horizon.app around the SPM binary.
set -euo pipefail
cd "$(dirname "$0")"

# Keep SwiftPM's release objects, compiler modules, and any icon scratch files
# in one private temporary directory. The finished app below is the only build
# output left in the workspace. SDKROOT is inherited unchanged when selected by
# the caller (for example, the installed Command Line Tools SDK).
build_tmp=$(mktemp -d "${TMPDIR:-/tmp}/horizon-app-build.XXXXXX")
build_lock_prefix=""
cleanup_build() {
  rm -rf "$build_tmp"
  # SwiftPM also leaves lock files in NSTemporaryDirectory, outside scratch.
  # Remove only locks whose names include this unique build directory.
  if [[ -n "$build_lock_prefix" ]]; then
    for build_lock_file in "${TMPDIR:-/tmp}"/"${build_lock_prefix}"*.lock; do
      if [[ -f "$build_lock_file" ]]; then rm -f "$build_lock_file"; fi
    done
  fi
}
trap cleanup_build EXIT
build_lock_prefix=$(cd "$build_tmp" && pwd -P)
build_lock_prefix="${build_lock_prefix//\//_}_"
build_path="$build_tmp/swiftpm"
export CLANG_MODULE_CACHE_PATH="$build_tmp/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_tmp/swift-module-cache"
swift_args=(build -c release --scratch-path "$build_path"
  --cache-path "$build_tmp/cache" --config-path "$build_tmp/config"
  --security-path "$build_tmp/security" --skip-update
  -Xswiftc -module-cache-path -Xswiftc "$build_tmp/swift-module-cache"
  -Xcc "-fmodules-cache-path=$build_tmp/clang-module-cache")
if [[ "${HORIZON_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
  swift_args+=(--disable-sandbox)
fi
swift "${swift_args[@]}"
bin_path=$(swift "${swift_args[@]}" --show-bin-path)

# Regenerate the icon set. The badge fills 100% of the canvas width (it is
# 1.27:1, so a square icon must letterbox it vertically -- that IS maximal).
# The 1024px slot is dropped: it was 862KB of the 1.9MB icns and nothing here
# renders the icon above 512px.
if [ Resources/icon-1024.png -nt Resources/AppIcon.icns ]; then
  iconset="$build_tmp/AppIcon.iconset"
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" Resources/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    if [ "$d" -le 512 ]; then
      sips -z "$d" "$d" Resources/icon-1024.png \
        --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
    fi
  done
  iconutil -c icns "$iconset" -o Resources/AppIcon.icns
fi
APP="Horizon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin_path/horizon" "$APP/Contents/MacOS/Horizon"
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
