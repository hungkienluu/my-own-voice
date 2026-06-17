#!/usr/bin/env bash
set -euo pipefail

MODE="run"
BUILD_CONFIGURATION="${MY_OWN_VOICE_BUILD_CONFIGURATION:-debug}"
APP_NAME="MyOwnVoiceApp"
APP_DISPLAY_NAME="My Own Voice"
BUNDLE_ID="com.hungkienluu.myownvoice"
APP_VERSION="${APP_VERSION:-0.2.0}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="14.0"
MICROPHONE_USAGE_DESCRIPTION="My Own Voice needs microphone access to capture local dictation audio."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
LOG_DIR="$DIST_DIR/logs"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
STDOUT_LOG="$LOG_DIR/$APP_NAME.stdout.log"
STDERR_LOG="$LOG_DIR/$APP_NAME.stderr.log"

BUILD_BINARY=""
SOURCE_EPOCH=""
SOURCE_TIMESTAMP=""

source "$ROOT_DIR/script/swiftpm_env.sh"

usage() {
  cat <<EOF
usage: $0 [run|--debug|--logs|--telemetry|--verify] [--release|--configuration debug|release]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$1"
      shift
      ;;
    --release)
      BUILD_CONFIGURATION="release"
      shift
      ;;
    --configuration)
      if [[ $# -lt 2 ]]; then
        echo "--configuration requires debug or release" >&2
        exit 2
      fi
      BUILD_CONFIGURATION="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$BUILD_CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "Unsupported build configuration: $BUILD_CONFIGURATION" >&2
    usage >&2
    exit 2
    ;;
esac

stop_existing_app() {
  echo "==> Stopping any previous $APP_NAME process"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 1
}

latest_app_source_epoch() {
  find Package.swift Sources -type f -print0 \
    | xargs -0 stat -f "%m" \
    | sort -nr \
    | head -n 1
}

build_binary() {
  local build_args=(--product "$APP_NAME")

  if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    build_args=(-c release --product "$APP_NAME")
  fi

  echo "==> Building $APP_NAME with swift build ($BUILD_CONFIGURATION)"
  swift build "${SWIFTPM_COMMON_ARGS[@]}" "${build_args[@]}"
  if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    BUILD_BINARY="$(swift build "${SWIFTPM_COMMON_ARGS[@]}" -c release --show-bin-path)/$APP_NAME"
  else
    BUILD_BINARY="$(swift build "${SWIFTPM_COMMON_ARGS[@]}" --show-bin-path)/$APP_NAME"
  fi

  if [[ ! -x "$BUILD_BINARY" ]]; then
    echo "Expected built executable at $BUILD_BINARY" >&2
    exit 1
  fi

  echo "==> Built executable: $BUILD_BINARY"
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

bundle_app() {
  local codesign_requirement

  echo "==> Bundling a real macOS app at $APP_BUNDLE"
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$LOG_DIR"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  write_info_plist
  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
  codesign_requirement="designated => identifier \"$BUNDLE_ID\""
  echo "==> Signing bundle with stable requirement: $codesign_requirement"
  /usr/bin/codesign --force --deep --sign - -r="$codesign_requirement" "$APP_BUNDLE" >/dev/null
}

launch_app() {
  echo "==> Launching $APP_BUNDLE with /usr/bin/open -n"
  : >"$STDOUT_LOG"
  : >"$STDERR_LOG"
  if ! /usr/bin/open -n -i /dev/null -o "$STDOUT_LOG" --stderr "$STDERR_LOG" "$APP_BUNDLE"; then
    echo "==> Launch failed; staged bundle diagnostics" >&2
    if [[ -x "$APP_BINARY" ]]; then
      echo "    executable: present at $APP_BINARY" >&2
      /usr/bin/file "$APP_BINARY" >&2 || true
    else
      echo "    executable: missing or not executable at $APP_BINARY" >&2
    fi

    if [[ -f "$INFO_PLIST" ]]; then
      echo "    Info.plist CFBundleExecutable:" >&2
      /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" >&2 || true
      /usr/bin/plutil -lint "$INFO_PLIST" >&2 || true
    else
      echo "    Info.plist: missing at $INFO_PLIST" >&2
    fi

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >&2 || true
    echo "    If the bundle diagnostics are valid but LaunchServices reports kLSNoExecutableErr, rerun from a normal desktop shell; Codex sandboxing can hide executable metadata from /usr/bin/open." >&2
    return 1
  fi
  sleep 2
}

print_recent_logs() {
  echo "==> stdout log: $STDOUT_LOG"
  if [[ -s "$STDOUT_LOG" ]]; then
    tail -n 20 "$STDOUT_LOG"
  else
    echo "(stdout is empty so far)"
  fi

  echo "==> stderr log: $STDERR_LOG"
  if [[ -s "$STDERR_LOG" ]]; then
    tail -n 20 "$STDERR_LOG"
  else
    echo "(stderr is empty so far)"
  fi

  echo "==> Unified log command"
  echo "/usr/bin/log stream --info --style compact --predicate 'process == \"$APP_NAME\"'"
}

print_readiness_snapshot() {
  echo "==> QA readiness snapshot"
  echo "==> Building FocusedInsertionProbe for readiness checks"
  swift build "${SWIFTPM_COMMON_ARGS[@]}" --product FocusedInsertionProbe
  bash "$ROOT_DIR/script/qa_status.sh"
}

verify_launch() {
  echo "==> Verifying bundle metadata"
  [[ -d "$APP_BUNDLE" ]]
  [[ -x "$APP_BINARY" ]]
  /usr/bin/plutil -p "$INFO_PLIST" >/dev/null

  local package_type
  package_type="$(
    /usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$INFO_PLIST"
  )"
  if [[ "$package_type" != "APPL" ]]; then
    echo "Expected CFBundlePackageType to be APPL but found $package_type" >&2
    exit 1
  fi

  echo "==> Verifying launched process"
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME is not running after launch" >&2
    exit 1
  fi

  pgrep -lf "$APP_NAME" 2>/dev/null || true

  local content_type
  content_type="$(mdls -raw -name kMDItemContentType "$APP_BUNDLE" 2>/dev/null || true)"
  echo "==> Spotlight content type: ${content_type:-unknown}"
}

run_flow() {
  stop_existing_app
  build_binary
  bundle_app
}

case "$MODE" in
  run)
    run_flow
    launch_app
    verify_launch
    print_recent_logs
    ;;
  --debug|debug)
    run_flow
    exec lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    run_flow
    launch_app
    verify_launch
    print_recent_logs
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    run_flow
    launch_app
    verify_launch
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    run_flow
    launch_app
    verify_launch
    print_recent_logs
    print_readiness_snapshot
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
