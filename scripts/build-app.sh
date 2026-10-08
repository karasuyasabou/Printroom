#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
arch="$(uname -m)"
if [[ "$#" == 2 && "$1" == "--arch" ]]; then
  arch="$2"
elif [[ "$#" != 0 ]]; then
  echo "Usage: scripts/build-app.sh [--arch arm64|x86_64]" >&2
  exit 1
fi
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
swift build --build-system native -c release --disable-sandbox --arch "$arch"
bin_dir="$(swift build --build-system native -c release --disable-sandbox --arch "$arch" --show-bin-path)"
mkdir -p "$PWD/output"
staging=$(mktemp -d "$PWD/output/.printroom-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Printroom.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Assets/ICC"
cp "$bin_dir/Printroom" "$app/Contents/MacOS/Printroom"
cp assets/AppIcon/Printroom.icns "$app/Contents/Resources/Printroom.icns"
mkdir -p "$app/Contents/Resources/ThirdParty"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp -R ThirdParty/LibRaw "$app/Contents/Resources/ThirdParty/LibRaw"
cp -R "$bin_dir/Printroom_PrintroomCore.bundle" "$app/Contents/Resources/"
cp ICC/DCIP3_D65.icc "$app/Contents/Resources/Assets/ICC/"
mkdir -p "$app/Contents/Resources/Assets/assets/DerivedLUTs"
cp -R assets/DerivedLUTs/diffuse-white-v1 "$app/Contents/Resources/Assets/assets/DerivedLUTs/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Printroom</string>
<key>CFBundleIdentifier</key><string>studio.printroom.local.v3.3</string>
<key>CFBundleName</key><string>Printroom</string>
<key>CFBundleDisplayName</key><string>Printroom</string>
<key>CFBundleIconFile</key><string>Printroom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>TIFF or RAW Image</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.tiff</string><string>public.camera-raw-image</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
# Cross-built packages are not executed on the build host.
if [[ "$arch" == "$(uname -m)" ]]; then
  "$app/Contents/MacOS/Printroom" --verify-resources
fi
codesign --verify --deep --strict "$app"
rm -rf "$PWD/output/Printroom.app"
mv "$app" "$PWD/output/Printroom.app"
echo "Built: $PWD/output/Printroom.app"
