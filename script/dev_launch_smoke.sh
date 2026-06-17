#!/usr/bin/env bash
set -euo pipefail

BUILD_CONFIGURATION="${MY_OWN_VOICE_DEV_BUILD_CONFIGURATION:-debug}"
APP_PRODUCT_NAME="MyOwnVoiceApp"
APP_NAME="MyOwnVoiceDev"
APP_DISPLAY_NAME="My Own Voice Dev"
BUNDLE_ID="com.hungkienluu.myownvoice.dev"
MIN_SYSTEM_VERSION="14.0"
MICROPHONE_USAGE_DESCRIPTION="My Own Voice Dev needs microphone access to capture local dictation audio."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/dev-smoke"
LOG_DIR="$DIST_DIR/logs"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
STDOUT_LOG="$LOG_DIR/$APP_NAME.stdout.log"
STDERR_LOG="$LOG_DIR/$APP_NAME.stderr.log"
SAMPLE_SECONDS="${MY_OWN_VOICE_DEV_SAMPLE_SECONDS:-0}"
SAMPLE_MAX_PHYSICAL_FOOTPRINT_MB="${MY_OWN_VOICE_DEV_MAX_PHYSICAL_FOOTPRINT_MB:-500}"
SAMPLE_LOG="$LOG_DIR/$APP_NAME.sample.txt"
SOURCE_EPOCH=""
SOURCE_TIMESTAMP=""

source "$ROOT_DIR/script/swiftpm_env.sh"

usage() {
  cat <<EOF
usage: $0 [--release|--configuration debug|release]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

cleanup() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

latest_app_source_epoch() {
  find Package.swift Sources -type f -print0 \
    | xargs -0 stat -f "%m" \
    | sort -nr \
    | head -n 1
}

physical_footprint_mb() {
  local sample_log="$1"

  awk -F: '
    /Physical footprint \(peak\)/ {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      unit = substr(value, length(value), 1)
      amount = substr(value, 1, length(value) - 1) + 0

      if (unit == "G") {
        amount *= 1024
      } else if (unit == "K") {
        amount /= 1024
      } else if (unit != "M") {
        amount = value + 0
      }

      printf "%.1f\n", amount
      exit
    }
  ' "$sample_log"
}

number_greater_than() {
  local value="$1"
  local limit="$2"

  awk -v value="$value" -v limit="$limit" 'BEGIN { exit !(value > limit) }'
}

cd "$ROOT_DIR"
trap cleanup EXIT

build_args=(--product "$APP_PRODUCT_NAME")

if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  build_args=(-c release --product "$APP_PRODUCT_NAME")
fi

echo "==> Building $APP_PRODUCT_NAME for dev launch smoke ($BUILD_CONFIGURATION)"
swift build "${SWIFTPM_COMMON_ARGS[@]}" "${build_args[@]}"
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  BUILD_BINARY="$(swift build "${SWIFTPM_COMMON_ARGS[@]}" -c release --show-bin-path)/$APP_PRODUCT_NAME"
else
  BUILD_BINARY="$(swift build "${SWIFTPM_COMMON_ARGS[@]}" --show-bin-path)/$APP_PRODUCT_NAME"
fi

if [[ ! -x "$BUILD_BINARY" ]]; then
  echo "Expected built executable at $BUILD_BINARY" >&2
  exit 1
fi

SOURCE_EPOCH="$(latest_app_source_epoch)"
SOURCE_TIMESTAMP="$(date -r "$SOURCE_EPOCH" "+%Y-%m-%d %H:%M:%S %Z")"

echo "==> Staging isolated dev app at $APP_BUNDLE"
cleanup
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$LOG_DIR"
rm -f "$APP_BINARY"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
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

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
/usr/bin/codesign --force --deep --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP_BUNDLE" >/dev/null

echo "==> Launching isolated dev app"
: >"$STDOUT_LOG"
: >"$STDERR_LOG"
/usr/bin/open -n -i /dev/null -o "$STDOUT_LOG" --stderr "$STDERR_LOG" "$APP_BUNDLE"
sleep 2

echo "==> Verifying isolated dev process"
if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME is not running after launch" >&2
  echo "==> stderr log: $STDERR_LOG" >&2
  tail -n 20 "$STDERR_LOG" >&2 || true
  exit 1
fi

pgrep -lf "$APP_NAME" 2>/dev/null || true

if [[ -s "$STDERR_LOG" ]]; then
  echo "==> Recent stderr"
  tail -n 20 "$STDERR_LOG"
else
  echo "==> stderr is empty"
fi

if [[ "$SAMPLE_SECONDS" != "0" ]]; then
  APP_PID="$(pgrep -x "$APP_NAME" 2>/dev/null | head -n 1)"
  if command -v sample >/dev/null 2>&1; then
    echo "==> Sampling isolated dev app for ${SAMPLE_SECONDS}s"
    sample "$APP_PID" "$SAMPLE_SECONDS" -file "$SAMPLE_LOG" >/dev/null
    grep -E "Physical footprint|Physical footprint \\(peak\\)" "$SAMPLE_LOG" || true
    SAMPLE_PEAK_MB="$(physical_footprint_mb "$SAMPLE_LOG")"
    if [[ -n "$SAMPLE_PEAK_MB" ]]; then
      echo "==> Peak physical footprint: ${SAMPLE_PEAK_MB}M (limit ${SAMPLE_MAX_PHYSICAL_FOOTPRINT_MB}M)"
      if number_greater_than "$SAMPLE_PEAK_MB" "$SAMPLE_MAX_PHYSICAL_FOOTPRINT_MB"; then
        echo "Peak physical footprint ${SAMPLE_PEAK_MB}M exceeds limit ${SAMPLE_MAX_PHYSICAL_FOOTPRINT_MB}M" >&2
        exit 1
      fi
    else
      echo "==> Could not parse peak physical footprint from sample log; skipping footprint threshold"
    fi
    echo "==> Sample log: $SAMPLE_LOG"
  else
    echo "==> sample command is unavailable; skipping process sample"
  fi
fi

echo "==> Isolated dev launch smoke passed"
