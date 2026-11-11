#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
BIN_DIR=$(swift build --disable-sandbox -c release --show-bin-path)
APP="$PWD/build/Deadline Startup.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ -f Assets/AppIcon.png ]]; then
    ./scripts/build-icon.sh
    cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$BIN_DIR/DeadlineStartup" "$APP/Contents/MacOS/DeadlineStartup"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DeadlineStartup</string>
<key>CFBundleIdentifier</key><string>com.deadlinestartup.app</string>
<key>CFBundleName</key><string>Deadline Startup</string>
<key>CFBundleDisplayName</key><string>Deadline Startup</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>3.1</string>
<key>CFBundleVersion</key><string>22</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
