#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/短信验证码调试.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$ROOT_DIR/.build/release/SmsCodeMenuBar" "$MACOS_PATH/SmsCodeMenuBar"

ICON_SOURCE="$ROOT_DIR/图标/appicon.png"
MENU_BAR_ICON_SOURCE="$ROOT_DIR/图标/menubar.png"

if [[ -f "$ICON_SOURCE" ]]; then
    ICON_WORK_DIR="$(mktemp -d)"
    ICON_PNG="$ICON_WORK_DIR/appicon-source.png"
    ICONSET_PATH="$ICON_WORK_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET_PATH"
    sips -s format png "$ICON_SOURCE" --out "$ICON_PNG" >/dev/null
    sips -z 16 16 "$ICON_PNG" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_PNG" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_PNG" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_PNG" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_PNG" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_PNG" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_PNG" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_PNG" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_PNG" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_PATH/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET_PATH" -o "$RESOURCES_PATH/AppIcon.icns"
    rm -rf "$ICON_WORK_DIR"
fi

if [[ -f "$MENU_BAR_ICON_SOURCE" ]]; then
    sips -s format png "$MENU_BAR_ICON_SOURCE" --out "$RESOURCES_PATH/menubar.png" >/dev/null
fi

cat > "$CONTENTS_PATH/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>短信验证码调试</string>
    <key>CFBundleExecutable</key>
    <string>SmsCodeMenuBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.sms-code-menubar.debug</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>短信验证码调试</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>用于在验证码无法自动输入时发送系统通知。</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${SMS_CODE_SIGN_IDENTITY:-SmsCodeMenuBar Local Code Signing}"
if security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\""; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH"
else
    echo "warning: 未找到稳定签名身份 '$SIGN_IDENTITY'，将使用临时签名。macOS 权限可能在每次构建后失效。" >&2
    codesign --force --deep --sign - "$APP_PATH"
fi
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "$APP_PATH"
