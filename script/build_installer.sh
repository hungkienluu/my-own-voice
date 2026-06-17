#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MyOwnVoiceApp"
APP_DISPLAY_NAME="My Own Voice"
BUNDLE_ID="com.hungkienluu.myownvoice"
APP_VERSION="${APP_VERSION:-0.2.0}"
APP_BUILD="${APP_BUILD:-1}"
BUILD_CONFIGURATION="release"
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
CREATE_PKG="${CREATE_PKG:-true}"
NOTARIZE="${NOTARIZE:-false}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-60m}"

BUILD_BINARY=""
SOURCE_EPOCH=""
SOURCE_TIMESTAMP=""
NOTARIZATION_ZIP_PATH="$DIST_DIR/${APP_DISPLAY_NAME// /-}-$APP_VERSION-notary.zip"

source "$ROOT_DIR/script/swiftpm_env.sh"

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

validate_release_configuration() {
  if ! is_truthy "$NOTARIZE"; then
    return
  fi

  if [[ "$APP_CODESIGN_IDENTITY" == "-" ]]; then
    cat >&2 <<EOF
NOTARIZE=true requires a Developer ID Application signing identity.
Set APP_CODESIGN_IDENTITY, for example:
  APP_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
EOF
    exit 1
  fi

  if is_truthy "$CREATE_PKG" && [[ -z "$INSTALLER_SIGN_IDENTITY" ]]; then
    cat >&2 <<EOF
NOTARIZE=true with CREATE_PKG=true requires a Developer ID Installer signing identity.
Set INSTALLER_SIGN_IDENTITY, for example:
  INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
Or build only the stapled zip with CREATE_PKG=false.
EOF
    exit 1
  fi

  if [[ -z "$NOTARY_KEYCHAIN_PROFILE" ]] &&
     { [[ -z "$NOTARY_APPLE_ID" ]] || [[ -z "$NOTARY_TEAM_ID" ]] || [[ -z "$NOTARY_PASSWORD" ]]; }; then
    cat >&2 <<EOF
NOTARIZE=true requires notarytool credentials.
Preferred setup:
  xcrun notarytool store-credentials my-own-voice-notary \\
    --apple-id you@example.com \\
    --team-id TEAMID \\
    --password xxxx-xxxx-xxxx-xxxx

Then run with:
  NOTARY_KEYCHAIN_PROFILE=my-own-voice-notary

Alternatively set NOTARY_APPLE_ID, NOTARY_TEAM_ID, and NOTARY_PASSWORD.
EOF
    exit 1
  fi
}

latest_app_source_epoch() {
  find Package.swift Sources -type f -print0 \
    | xargs -0 stat -f "%m" \
    | sort -nr \
    | head -n 1
}

build_release_binary() {
  echo "==> Building $APP_NAME in release mode"
  swift build "${SWIFTPM_COMMON_ARGS[@]}" -c release --product "$APP_NAME"
  BUILD_BINARY="$(swift build "${SWIFTPM_COMMON_ARGS[@]}" -c release --show-bin-path)/$APP_NAME"

  if [[ ! -x "$BUILD_BINARY" ]]; then
    echo "Expected built executable at $BUILD_BINARY" >&2
    exit 1
  fi

  echo "==> Built release executable: $BUILD_BINARY"
  SOURCE_EPOCH="$(latest_app_source_epoch)"
  SOURCE_TIMESTAMP="$(date -r "$SOURCE_EPOCH" "+%Y-%m-%d %H:%M:%S %Z")"
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
  <key>MyOwnVoiceBuildConfiguration</key>
  <string>$BUILD_CONFIGURATION</string>
  <key>MyOwnVoiceSourceEpoch</key>
  <string>$SOURCE_EPOCH</string>
  <key>MyOwnVoiceSourceTimestamp</key>
  <string>$SOURCE_TIMESTAMP</string>
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
  local codesign_requirement

  echo "==> Signing app bundle with identity: $APP_CODESIGN_IDENTITY"

  local args=(
    --force
    --deep
    --sign "$APP_CODESIGN_IDENTITY"
  )

  if [[ "$APP_CODESIGN_IDENTITY" == "-" ]]; then
    codesign_requirement="designated => identifier \"$BUNDLE_ID\""
    echo "==> Applying stable ad-hoc requirement: $codesign_requirement"
    args+=("-r=$codesign_requirement")
  else
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

submit_to_notary_service() {
  local artifact_path="$1"
  local args=(
    submit
    "$artifact_path"
    --wait
    --timeout "$NOTARY_TIMEOUT"
  )

  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    args+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  else
    args+=(
      --apple-id "$NOTARY_APPLE_ID"
      --team-id "$NOTARY_TEAM_ID"
      --password "$NOTARY_PASSWORD"
    )
  fi

  echo "==> Submitting to Apple notary service: $artifact_path"
  xcrun notarytool "${args[@]}"
}

notarize_app_bundle() {
  if ! is_truthy "$NOTARIZE"; then
    return
  fi

  echo "==> Creating temporary app notarization archive at $NOTARIZATION_ZIP_PATH"
  rm -f "$NOTARIZATION_ZIP_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARIZATION_ZIP_PATH"

  submit_to_notary_service "$NOTARIZATION_ZIP_PATH"

  echo "==> Stapling notarization ticket to app bundle"
  xcrun stapler staple -v "$APP_BUNDLE"
  xcrun stapler validate -v "$APP_BUNDLE"
  /usr/sbin/spctl --assess --type execute -vv "$APP_BUNDLE"

  rm -f "$NOTARIZATION_ZIP_PATH"
}

create_pkg() {
  if ! is_truthy "$CREATE_PKG"; then
    echo "==> Skipping installer package because CREATE_PKG=false"
    return
  fi

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

notarize_pkg() {
  if ! is_truthy "$NOTARIZE" || ! is_truthy "$CREATE_PKG"; then
    return
  fi

  submit_to_notary_service "$PKG_PATH"

  echo "==> Stapling notarization ticket to installer package"
  xcrun stapler staple -v "$PKG_PATH"
  xcrun stapler validate -v "$PKG_PATH"
  /usr/sbin/spctl --assess --type install -vv "$PKG_PATH"
}

print_summary() {
  local pkg_summary="$PKG_PATH"
  if ! is_truthy "$CREATE_PKG"; then
    pkg_summary="skipped"
  fi

  cat <<EOF
==> Distribution artifacts
App bundle: $APP_BUNDLE
Zip:        $ZIP_PATH
Installer:  $pkg_summary

Notes:
- Local models are not bundled in these artifacts.
- The app's Models pane includes a Set Up Runtime action that opens/starts Ollama and pulls Gemma 4 when needed.
- Notarized: $NOTARIZE
EOF
}

validate_release_configuration
build_release_binary
bundle_release_app
sign_release_app
notarize_app_bundle
create_zip
create_pkg
notarize_pkg
print_summary
