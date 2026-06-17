#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEXT="${*:-my own voice insertion probe new line second line}"
DELAY_SECONDS="${MY_OWN_VOICE_PROBE_DELAY_SECONDS:-5}"
VERIFY_DELAY_SECONDS="${MY_OWN_VOICE_PROBE_VERIFY_DELAY_SECONDS:-1}"
PROBE_PROCESS="${MY_OWN_VOICE_PROBE_PROCESS:-helper}"
RESTORE_CLIPBOARD="${MY_OWN_VOICE_PROBE_RESTORE_CLIPBOARD:-false}"

cd "$ROOT_DIR"
source "$ROOT_DIR/script/swiftpm_env.sh"

focused_insertion_probe_binary() {
  local latest_source_epoch
  local binary
  local binary_epoch

  [[ -d "$ROOT_DIR/.build" ]] || return 1

  latest_source_epoch="$(find "$ROOT_DIR/Package.swift" "$ROOT_DIR/Sources/AppCore" "$ROOT_DIR/Sources/ModelRouting" "$ROOT_DIR/Tests/FocusedInsertionProbe" -type f -print0 \
    | xargs -0 stat -f "%m" \
    | sort -nr \
    | head -n 1)"

  binary="$(find "$ROOT_DIR/.build" -path "*/FocusedInsertionProbe" -type f -perm +111 -print 2>/dev/null \
    | sort -r \
    | head -n 1)"

  [[ -n "$binary" ]] || return 1

  binary_epoch="$(stat -f "%m" "$binary")"
  [[ "$binary_epoch" -ge "$latest_source_epoch" ]] || return 1
  printf "%s\n" "$binary"
}

running_app_binary() {
  local pids
  local pid
  local command_path

  pids="$(pgrep -x "MyOwnVoiceApp" 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 1

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command_path="$(ps -o command= -p "$pid" | awk '{print $1}')"
    if [[ -x "$command_path" ]]; then
      printf "%s\n" "$command_path"
      return 0
    fi
  done <<<"$pids"

  return 1
}

run_focused_insertion_probe() {
  local probe_binary

  case "$PROBE_PROCESS" in
    app)
      if probe_binary="$(running_app_binary)" && [[ -n "$probe_binary" ]]; then
        if [[ "$RESTORE_CLIPBOARD" == true ]]; then
          "$probe_binary" --probe-insertion --restore-clipboard --verify-delay "$VERIFY_DELAY_SECONDS" "$TEXT"
        else
          "$probe_binary" --probe-insertion --verify-delay "$VERIFY_DELAY_SECONDS" "$TEXT"
        fi
      else
        echo "MyOwnVoiceApp is not running. Run ./script/build_and_run.sh --release --verify first." >&2
        return 1
      fi
      ;;
    helper)
      if probe_binary="$(focused_insertion_probe_binary)" && [[ -n "$probe_binary" ]]; then
        if [[ "$RESTORE_CLIPBOARD" == true ]]; then
          "$probe_binary" --restore-clipboard --verify-delay "$VERIFY_DELAY_SECONDS" "$TEXT"
        else
          "$probe_binary" --verify-delay "$VERIFY_DELAY_SECONDS" "$TEXT"
        fi
      else
        if [[ "$RESTORE_CLIPBOARD" == true ]]; then
          swift run "${SWIFTPM_COMMON_ARGS[@]}" FocusedInsertionProbe --restore-clipboard --verify-delay "$VERIFY_DELAY_SECONDS" "$TEXT"
        else
          swift run "${SWIFTPM_COMMON_ARGS[@]}" FocusedInsertionProbe --verify-delay "$VERIFY_DELAY_SECONDS" "$TEXT"
        fi
      fi
      ;;
    *)
      echo "Unsupported MY_OWN_VOICE_PROBE_PROCESS=$PROBE_PROCESS; use helper or app." >&2
      return 2
      ;;
  esac
}

echo "==> Focus an editable field in the target app."
echo "==> Probe text: $TEXT"
echo "==> Probe process: $PROBE_PROCESS"
echo "==> Restore clipboard: $RESTORE_CLIPBOARD"
echo "==> Delayed visibility check: ${VERIFY_DELAY_SECONDS}s after insertion"

for ((remaining = DELAY_SECONDS; remaining > 0; remaining--)); do
  echo "==> Inserting in ${remaining}s..."
  sleep 1
done

run_focused_insertion_probe
