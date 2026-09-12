#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MoneyBook"
DISPLAY_NAME="记账本"
BUNDLE_ID="com.local.moneybook"
MIN_SYSTEM_VERSION="14.0"
SUBSYSTEM="com.local.moneybook"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_RESOURCES="$APP_CONTENTS/Resources"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"

# 本机 Xcode 未通过 xcode-select 选中，且 SwiftPM 默认缓存目录位于 $HOME（沙箱不可写），
# 因此显式指定工具链并把全部缓存重定向到项目内的 .build 目录。
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "找不到 Xcode：$DEVELOPER_DIR" >&2
  exit 1
fi

CACHE_ROOT="$ROOT_DIR/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

SWIFT_ARGS=(
  --disable-sandbox
  --scratch-path "$ROOT_DIR/.build"
  --cache-path "$CACHE_ROOT/cache"
  --config-path "$CACHE_ROOT/config"
  --security-path "$CACHE_ROOT/security"
)

build() {
  swift build "${SWIFT_ARGS[@]}"
}

stage_bundle() {
  local build_binary
  build_binary="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  # 应用图标：由 script/make_app_icon.swift 生成，随包一起分发。
  if [[ -f "$ICON_FILE" ]]; then
    cp "$ICON_FILE" "$APP_RESOURCES/AppIcon.icns"
  else
    echo "提示：缺少 $ICON_FILE，可运行 swift script/make_app_icon.swift Resources 生成" >&2
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

case "$MODE" in
  run)
    build
    stage_bundle
    open_app
    ;;
  --debug|debug)
    build
    stage_bundle
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build
    stage_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build
    stage_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$SUBSYSTEM\""
    ;;
  --verify|verify)
    build
    stage_bundle
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME 已启动"
    ;;
  --selftest|selftest)
    build
    "$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/$APP_NAME" --selftest
    ;;
  --test|test)
    swift test "${SWIFT_ARGS[@]}"
    ;;
  --icon|icon)
    # 重新生成应用图标：脚本绘制 → iconutil 打包成 .icns
    swift "$ROOT_DIR/script/make_app_icon.swift" "$ROOT_DIR/Resources"
    iconutil -c icns "$ROOT_DIR/Resources/AppIcon.iconset" -o "$ROOT_DIR/Resources/AppIcon.icns"
    echo "已生成 Resources/AppIcon.icns"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--selftest|--test|--icon]" >&2
    exit 2
    ;;
esac
