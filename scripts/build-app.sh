#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
app="$PWD/output/${1:-Printroom-0.3.3}.app"
case "${app##*/}" in
  Printroom-0.1.0*.app|Printroom-0.2.0*.app|Printroom-0.3.0*.app|Printroom-0.3.1*.app|Printroom-0.3.2*.app)
    echo "Refusing to replace a preserved older app; choose a separate bundle name." >&2
    exit 1
    ;;
esac
swift build -c release --disable-sandbox
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Assets/ICC" "$app/Contents/Resources/Assets/LUT"
cp .build/release/Printroom "$app/Contents/MacOS/Printroom"
cp -R .build/release/Printroom_PrintroomCore.bundle "$app/Contents/Resources/"
cp ICC/DCIP3_D65.icc "$app/Contents/Resources/Assets/ICC/"
cp 'LUT/DCI-P3 Kodak 2383 D65.cube' "$app/Contents/Resources/Assets/LUT/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Printroom</string>
<key>CFBundleIdentifier</key><string>studio.printroom.local.v3.3</string>
<key>CFBundleName</key><string>Printroom</string>
<key>CFBundleDisplayName</key><string>Printroom 0.3.3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.3</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>TIFF Image</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.tiff</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/Printroom" --verify-resources
echo "Built: $app"
