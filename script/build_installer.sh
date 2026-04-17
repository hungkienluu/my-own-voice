#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MyOwnVoiceApp"
APP_DISPLAY_NAME="My Own Voice"
BUNDLE_ID="com.hungkienluu.myownvoice"
APP_VERSION="${APP_VERSION:-0.2.0}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="14.0"
MICROPHONE_USAGE_DESCRIPTION="My Own Voice needs microphone access to capture local dictation audio."
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PKG_PATH="$DIST_DIR/${APP_DISPLAY_NAME// /-}-$APP_VERSION.pkg"
ZIP_PATH="$DIST_DIR/${APP_DISPLAY_NAME// /-}-$APP_VERSION.zip"
APP_CODESIGN_IDENTITY="${APP_CODESIGN_IDENTITY:--}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"

BUILD_BINARY=""

build_release_binary() {
  echo "==> Building $APP_NAME in release mode"
  swift build -c release --product "$APP_NAME"
  BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

  if [[ ! -x "$BUILD_BINARY" ]]; then
    echo "Expected built executable at $BUILD_BINARY" >&2
    exit 1
  fi

  echo "==> Built release executable: $BUILD_BINARY"
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>$MICROPHONE_USAGE_DESCRIPTION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

bundle_release_app() {
  echo "==> Staging release bundle at $APP_BUNDLE"
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  write_info_plist
  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
}

sign_release_app() {
  echo "==> Signing app bundle with identity: $APP_CODESIGN_IDENTITY"

  local args=(
    --force
    --deep
    --sign "$APP_CODESIGN_IDENTITY"
  )

  if [[ "$APP_CODESIGN_IDENTITY" != "-" ]]; then
    args+=(--timestamp --options runtime)
  fi

  /usr/bin/codesign "${args[@]}" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
}

create_zip() {
  echo "==> Creating zip archive at $ZIP_PATH"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
}

create_pkg() {
  echo "==> Creating installer package at $PKG_PATH"
  rm -f "$PKG_PATH"

  local args=(
    --component "$APP_BUNDLE" /Applications
  )

  if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
    echo "==> Signing installer package with identity: $INSTALLER_SIGN_IDENTITY"
    args+=(--sign "$INSTALLER_SIGN_IDENTITY")
  fi

  /usr/bin/productbuild "${args[@]}" "$PKG_PATH"
  /usr/sbin/pkgutil --check-signature "$PKG_PATH" || true
}

print_summary() {
  cat <<EOF
==> Distribution artifacts
App bundle: $APP_BUNDLE
Zip:        $ZIP_PATH
Installer:  $PKG_PATH

Notes:
- Local models are not bundled in these artifacts.
- The app's Models pane includes a Set Up Runtime action that opens/starts Ollama and pulls Gemma 4 when needed.
- For frictionless distribution on another Mac, provide Developer ID signing identities and notarize the outputs.
EOF
}

build_release_binary
bundle_release_app
sign_release_app
create_zip
create_pkg
print_summary
