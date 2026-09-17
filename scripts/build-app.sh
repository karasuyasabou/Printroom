#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [ "$#" -ne 0 ]; then
  echo "Usage: scripts/build-app.sh (always replaces output/Printroom.app)" >&2
  exit 1
fi
swift build --build-system native -c release --disable-sandbox
mkdir -p "$PWD/output"
staging=$(mktemp -d "$PWD/output/.printroom-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Printroom.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Assets/ICC" "$app/Contents/Resources/Assets/LUT"
cp .build/release/Printroom "$app/Contents/MacOS/Printroom"
cp assets/AppIcon/Printroom.icns "$app/Contents/Resources/Printroom.icns"
mkdir -p "$app/Contents/Resources/ThirdParty"
cp -R ThirdParty/LibRaw "$app/Contents/Resources/ThirdParty/LibRaw"
cp -R .build/release/Printroom_PrintroomCore.bundle "$app/Contents/Resources/"
cp ICC/DCIP3_D65.icc "$app/Contents/Resources/Assets/ICC/"
cp 'LUT/DCI-P3 Fujifilm 3513DI D65.cube' "$app/Contents/Resources/Assets/LUT/"
cp 'LUT/DCI-P3 Kodak 2383 D65.cube' "$app/Contents/Resources/Assets/LUT/"
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
<key>CFBundleShortVersionString</key><string>0.3.40</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>TIFF or Sony RAW Image</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.tiff</string><string>com.sony.arw-raw-image</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/Printroom" --verify-resources
codesign --verify --deep --strict "$app"
rm -rf "$PWD/output/Printroom.app"
mv "$app" "$PWD/output/Printroom.app"
echo "Built: $PWD/output/Printroom.app"
