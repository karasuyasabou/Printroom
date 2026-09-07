#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox
app="$PWD/output/${1:-Printroom-0.2.0}.app"
if [[ "$app" == "$PWD/output/Printroom-0.1.0.app" ]]; then
  echo "Refusing to replace the preserved 0.1.0 app; choose a separate bundle name." >&2
  exit 1
fi
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
<key>CFBundleIdentifier</key><string>studio.printroom.local.v2</string>
<key>CFBundleName</key><string>Printroom</string>
<key>CFBundleDisplayName</key><string>Printroom 0.2.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>TIFF Image</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.tiff</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/Printroom" --verify-resources
echo "Built: $app"
