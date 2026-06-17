#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$ROOT_DIR/dist/MyOwnVoiceApp.app/Contents/MacOS/MyOwnVoiceApp"

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

ensure_focused_insertion_probe_binary() {
  local probe_binary

  if probe_binary="$(focused_insertion_probe_binary)" && [[ -n "$probe_binary" ]]; then
    printf "%s\n" "$probe_binary"
    return
  fi

  swift build "${SWIFTPM_COMMON_ARGS[@]}" --product FocusedInsertionProbe >/dev/null
  focused_insertion_probe_binary
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

run_app_request_command() {
  local app_binary="$1"
  local output_path
  local pid
  local attempt
  local exited=false
  local exit_status=0

  output_path="$(mktemp "${TMPDIR:-/tmp}/my-own-voice-app-accessibility.XXXXXX")"
  "$app_binary" --request-accessibility >"$output_path" 2>&1 &
  pid="$!"

  for attempt in {1..20}; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      sleep 0.25
    else
      if wait "$pid"; then
        exit_status=0
      else
        exit_status="$?"
      fi
      exited=true
      break
    fi
  done

  if [[ "$exited" != true ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    cat "$output_path"
    rm -f "$output_path"
    echo "note=MyOwnVoiceApp --request-accessibility did not exit quickly. Relaunch with ./script/build_and_run.sh --release --verify, then rerun this helper."
    return 0
  fi

  cat "$output_path"
  rm -f "$output_path"
  return "$exit_status"
}

console_session_entry() {
  ioreg -n Root -d1 2>/dev/null |
    tr '{}' '\n' |
    awk '/kCGSSessionOnConsoleKey"=Yes/ { print; exit }'
}

print_desktop_session_state() {
  local session_entry
  local session_user

  if ! command -v ioreg >/dev/null 2>&1; then
    echo "desktopSessionState=unavailable"
    echo "note=Could not inspect the desktop lock state because ioreg is unavailable."
    return
  fi

  session_entry="$(console_session_entry || true)"
  if [[ -z "$session_entry" ]]; then
    echo "desktopSessionState=unavailable"
    echo "note=Could not inspect the active console session."
    return
  fi

  session_user="$(sed -n 's/.*kCGSSessionUserNameKey"="\([^"]*\)".*/\1/p' <<<"$session_entry")"
  echo "desktopSessionUser=${session_user:-unknown}"

  if grep -q '"CGSSessionScreenIsLocked"=Yes' <<<"$session_entry"; then
    echo "desktopSessionScreenLocked=true"
    echo "note=Unlock the desktop before granting Accessibility entries or running target-app QA."
  elif grep -q '"kCGSessionLoginDoneKey"=Yes' <<<"$session_entry"; then
    echo "desktopSessionScreenLocked=false"
  else
    echo "desktopSessionScreenLocked=unknown"
    echo "note=Could not determine whether the desktop is locked."
  fi
}

request_app_accessibility() {
  local app_binary

  if app_binary="$(running_app_binary)" && [[ -n "$app_binary" ]]; then
    :
  elif [[ -x "$APP_BINARY" ]]; then
    app_binary="$APP_BINARY"
  else
    echo "requestingAccessibilityFor=MyOwnVoiceApp"
    echo "appBinary=unavailable"
    echo "note=Run ./script/build_and_run.sh --release --verify, then rerun this helper to request the My Own Voice app entry."
    return
  fi

  echo
  echo "requestingAccessibilityFor=MyOwnVoiceApp"
  echo "appBinary=$app_binary"
  if ! run_app_request_command "$app_binary"; then
    echo "note=MyOwnVoiceApp Accessibility request command exited with a nonzero status."
  fi
}

run_request() {
  local probe_binary

  print_desktop_session_state
  echo

  probe_binary="$(ensure_focused_insertion_probe_binary)"

  echo "requestingAccessibilityFor=FocusedInsertionProbe"
  echo "probeBinary=$probe_binary"
  "$probe_binary" --request-accessibility
  request_app_accessibility
  /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
  echo "note=Opened System Settings > Privacy & Security > Accessibility."
  echo "note=Grant the Accessibility entries for FocusedInsertionProbe and My Own Voice."
}

run_request
