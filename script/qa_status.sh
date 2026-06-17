#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=false
qa_issues=()
MAX_IDLE_CPU_PERCENT="${MY_OWN_VOICE_MAX_IDLE_CPU_PERCENT:-25}"
MAX_IDLE_RSS_KB="${MY_OWN_VOICE_MAX_IDLE_RSS_KB:-1500000}"
if [[ -n "${MY_OWN_VOICE_WHISPERKIT_MODEL_NAME:-}" ]]; then
  WHISPERKIT_MODEL_NAMES=("$MY_OWN_VOICE_WHISPERKIT_MODEL_NAME")
else
  WHISPERKIT_MODEL_NAMES=(
    "small.en"
    "large-v3-v20240930_turbo_632MB"
    "large-v3-v20240930_626MB"
  )
fi
WHISPERKIT_MODEL_ROOT="$HOME/Library/Application Support/MyOwnVoice/Models/WhisperKit/models/argmaxinc/whisperkit-coreml"
WHISPER_CPP_MODEL_FILE="$HOME/Library/Application Support/MyOwnVoice/Models/whisper/ggml-small.en.bin"

usage() {
  cat <<EOF
usage: $0 [--strict]
EOF
}

case "${1:-}" in
  "")
    ;;
  --strict)
    STRICT=true
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

cd "$ROOT_DIR"
source "$ROOT_DIR/script/swiftpm_env.sh"

record_issue() {
  qa_issues+=("$1")
}

latest_app_source_epoch() {
  find Package.swift Sources -type f -print0 \
    | xargs -0 stat -f "%m" \
    | sort -nr \
    | head -n 1
}

format_epoch() {
  local epoch="$1"
  date -r "$epoch" "+%Y-%m-%d %H:%M:%S %Z"
}

format_rss_mb() {
  local rss_kb="$1"
  awk -v rss="$rss_kb" 'BEGIN { printf "%.1fM", rss / 1024 }'
}

number_greater_than() {
  local value="$1"
  local limit="$2"

  awk -v value="$value" -v limit="$limit" 'BEGIN { exit !(value > limit) }'
}

process_start_epoch() {
  local start_time="$1"
  date -j -f "%a %b %e %T %Y" "$start_time" "+%s" 2>/dev/null || true
}

info_plist_for_executable() {
  local executable_path="$1"
  local macos_dir
  local contents_dir

  [[ -n "$executable_path" ]] || return 1
  [[ -f "$executable_path" ]] || return 1

  macos_dir="$(dirname "$executable_path")"
  contents_dir="$(cd "$macos_dir/.." 2>/dev/null && pwd -P)" || return 1

  if [[ -f "$contents_dir/Info.plist" ]]; then
    printf "%s\n" "$contents_dir/Info.plist"
  fi
}

plist_value() {
  local plist_path="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
}

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

run_focused_insertion_permission_check() {
  local probe_binary

  probe_binary="$(ensure_focused_insertion_probe_binary)"
  echo "probeBinary=$probe_binary"
  "$probe_binary" --check-permissions
}

running_process_executable() {
  local process_name="$1"
  local pids
  local pid
  local command_path

  pids="$(pgrep -x "$process_name" 2>/dev/null || true)"
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

run_app_permission_check() {
  local app_binary

  if app_binary="$(running_process_executable "MyOwnVoiceApp")" && [[ -n "$app_binary" ]]; then
    echo "appBinary=$app_binary"
    "$app_binary" --check-permissions
  else
    echo "appBinary=unavailable"
    return 1
  fi
}

file_size_summary() {
  local path="$1"

  du -sh "$path" 2>/dev/null | awk '{print $1}' || true
}

whisper_cpp_cli_path() {
  local candidate
  for candidate in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
    if [[ -x "$candidate" ]]; then
      printf "%s\n" "$candidate"
      return
    fi
  done
}

print_transcription_runtime_state() {
  local whisperkit_ready=false
  local whisper_cpp_ready=false
  local whisper_cpp_cli
  local whisperkit_model_name
  local whisperkit_model_dir
  local size

  for whisperkit_model_name in "${WHISPERKIT_MODEL_NAMES[@]}"; do
    whisperkit_model_dir="$WHISPERKIT_MODEL_ROOT/openai_whisper-${whisperkit_model_name}"
    if [[ -d "$whisperkit_model_dir" ]]; then
      whisperkit_ready=true
      size="$(file_size_summary "$whisperkit_model_dir")"
      printf "  %-15s ready: %s at %s%s\n" "WhisperKit" "$whisperkit_model_name" "$whisperkit_model_dir" "${size:+ ($size)}"
    else
      printf "  %-15s missing: %s at %s\n" "WhisperKit" "$whisperkit_model_name" "$whisperkit_model_dir"
    fi
  done

  whisper_cpp_cli="$(whisper_cpp_cli_path || true)"
  if [[ -n "$whisper_cpp_cli" && -f "$WHISPER_CPP_MODEL_FILE" ]]; then
    whisper_cpp_ready=true
    size="$(file_size_summary "$WHISPER_CPP_MODEL_FILE")"
    printf "  %-15s ready: %s with %s%s\n" "whisper.cpp" "$whisper_cpp_cli" "$WHISPER_CPP_MODEL_FILE" "${size:+ ($size)}"
  else
    if [[ -n "$whisper_cpp_cli" ]]; then
      printf "  %-15s partial: CLI found at %s, model missing at %s\n" "whisper.cpp" "$whisper_cpp_cli" "$WHISPER_CPP_MODEL_FILE"
    else
      printf "  %-15s missing: whisper-cli and/or model at %s\n" "whisper.cpp" "$WHISPER_CPP_MODEL_FILE"
    fi
  fi

  if [[ "$whisperkit_ready" != true && "$whisper_cpp_ready" != true ]]; then
    record_issue "No local speech recognition backend is ready"
  fi
}

find_app() {
  local label="$1"
  shift

  local app_names=()
  local bundle_ids=()
  local parsing_bundle_ids=false
  local arg
  local roots=(
    "/Applications"
    "$HOME/Applications"
    "/System/Applications"
  )

  local found=""
  local root
  local candidate
  local app_name
  local bundle_id
  local requested

  for arg in "$@"; do
    if [[ "$arg" == "--bundle-id" ]]; then
      parsing_bundle_ids=true
      continue
    fi

    if [[ "$parsing_bundle_ids" == true ]]; then
      bundle_ids+=("$arg")
    else
      app_names+=("$arg")
    fi
  done

  for app_name in "${app_names[@]}"; do
    for root in "${roots[@]}"; do
      [[ -d "$root" ]] || continue

      while IFS= read -r -d '' candidate; do
        found="$candidate"
        break
      done < <(find "$root" -maxdepth 3 -type d -name "$app_name" -print0 2>/dev/null)

      [[ -z "$found" ]] || break
    done

    [[ -z "$found" ]] || break
  done

  if [[ -z "$found" ]] && command -v mdfind >/dev/null 2>&1; then
    for bundle_id in "${bundle_ids[@]}"; do
      while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        [[ -d "$candidate" ]] || continue
        [[ "$candidate" == *.app ]] || continue
        found="$candidate"
        break
      done < <(mdfind "kMDItemCFBundleIdentifier == \"$bundle_id\"c" 2>/dev/null)

      [[ -z "$found" ]] || break
    done
  fi

  if [[ -n "$found" ]]; then
    printf "  %-8s found: %s\n" "$label" "$found"
  else
    requested="${app_names[*]}"
    if [[ "${#bundle_ids[@]}" -gt 0 ]]; then
      requested="$requested; bundle IDs: ${bundle_ids[*]}"
    fi
    printf "  %-8s missing: %s\n" "$label" "$requested"
    record_issue "Missing target app: $label ($requested)"
  fi
}

print_process_state() {
  local process_name="$1"
  local pids
  local pgrep_status
  local pid
  local start_time
  local start_epoch
  local command_path
  local executable_epoch
  local latest_source_epoch
  local info_plist_path
  local bundle_version
  local bundle_build
  local bundle_configuration
  local bundle_source_epoch
  local bundle_source_timestamp
  local process_cpu
  local process_rss_kb

  if pids="$(pgrep -x "$process_name" 2>/dev/null)"; then
    pgrep_status=0
  else
    pgrep_status=$?
  fi

  if [[ "$pgrep_status" -gt 1 ]]; then
    printf "  %-15s process list unavailable\n" "$process_name"
    if [[ "$process_name" == "MyOwnVoiceApp" ]]; then
      record_issue "$process_name process state is unavailable"
    fi
    return
  fi

  if [[ -z "$pids" ]]; then
    printf "  %-15s not running\n" "$process_name"
    if [[ "$process_name" == "MyOwnVoiceApp" ]]; then
      record_issue "$process_name is not running"
    fi
    return
  fi

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    start_time="$(ps -o lstart= -p "$pid" | xargs)"
    start_epoch="$(process_start_epoch "$start_time")"
    command_path="$(ps -o command= -p "$pid" | awk '{print $1}')"
    process_cpu="$(ps -o pcpu= -p "$pid" | xargs)"
    process_rss_kb="$(ps -o rss= -p "$pid" | xargs)"
    printf "  %-15s running: %s (started %s)\n" "$process_name" "$pid" "$start_time"

    if [[ -n "$command_path" ]]; then
      printf "  %-15s executable: %s\n" "" "$command_path"
    fi
    if [[ -n "$process_cpu" && -n "$process_rss_kb" ]]; then
      printf "  %-15s health: CPU %s%%, RSS %s\n" "" "$process_cpu" "$(format_rss_mb "$process_rss_kb")"
    fi

    if [[ "$process_name" == "MyOwnVoiceApp" ]]; then
      latest_source_epoch="$(latest_app_source_epoch)"

      if [[ -n "$process_cpu" ]] &&
          number_greater_than "$process_cpu" "$MAX_IDLE_CPU_PERCENT"; then
        printf "  %-15s warning: CPU exceeds idle readiness threshold (%s%%)\n" "" "$MAX_IDLE_CPU_PERCENT"
        record_issue "$process_name CPU exceeds idle readiness threshold (${process_cpu}% > ${MAX_IDLE_CPU_PERCENT}%)"
      fi

      if [[ -n "$process_rss_kb" ]] &&
          number_greater_than "$process_rss_kb" "$MAX_IDLE_RSS_KB"; then
        printf "  %-15s warning: RSS exceeds readiness threshold (%s)\n" "" "$(format_rss_mb "$MAX_IDLE_RSS_KB")"
        record_issue "$process_name RSS exceeds readiness threshold ($(format_rss_mb "$process_rss_kb") > $(format_rss_mb "$MAX_IDLE_RSS_KB"))"
      fi

      if info_plist_path="$(info_plist_for_executable "$command_path")" && [[ -n "$info_plist_path" ]]; then
        bundle_version="$(plist_value "$info_plist_path" "CFBundleShortVersionString")"
        bundle_build="$(plist_value "$info_plist_path" "CFBundleVersion")"
        bundle_configuration="$(plist_value "$info_plist_path" "MyOwnVoiceBuildConfiguration")"
        bundle_source_epoch="$(plist_value "$info_plist_path" "MyOwnVoiceSourceEpoch")"
        bundle_source_timestamp="$(plist_value "$info_plist_path" "MyOwnVoiceSourceTimestamp")"

        if [[ -n "$bundle_version" || -n "$bundle_build" ]]; then
          printf "  %-15s bundle: version %s build %s\n" "" "${bundle_version:-unknown}" "${bundle_build:-unknown}"
        fi
        if [[ -n "$bundle_configuration" ]]; then
          printf "  %-15s configuration: %s\n" "" "$bundle_configuration"
        fi
        if [[ -n "$bundle_source_timestamp" ]]; then
          printf "  %-15s source: %s\n" "" "$bundle_source_timestamp"
        fi
        if [[ "$bundle_source_epoch" =~ ^[0-9]+$ && "$bundle_source_epoch" -lt "$latest_source_epoch" ]]; then
          printf "  %-15s warning: bundle source metadata predates latest app source change (%s)\n" "" "$(format_epoch "$latest_source_epoch")"
          record_issue "$process_name bundle source metadata predates latest app source change"
        fi
      fi

      if [[ -f "$command_path" ]]; then
        executable_epoch="$(stat -f "%m" "$command_path")"
        if [[ "$executable_epoch" -lt "$latest_source_epoch" ]]; then
          printf "  %-15s warning: executable predates latest app source change (%s)\n" "" "$(format_epoch "$latest_source_epoch")"
          record_issue "$process_name executable predates latest app source change"
        else
          printf "  %-15s executable: built after latest app source change\n" ""
        fi
      fi

      if [[ -n "$start_epoch" && "$start_epoch" -lt "$latest_source_epoch" ]]; then
        printf "  %-15s warning: process started before latest app source change (%s)\n" "" "$(format_epoch "$latest_source_epoch")"
        record_issue "$process_name process started before latest app source change"
      elif [[ -n "$start_epoch" ]]; then
        printf "  %-15s current: process started after latest app source change\n" ""
      fi
    fi
  done <<<"$pids"
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
    echo "  console session: unavailable (ioreg not found)"
    record_issue "Desktop session state is unavailable"
    return
  fi

  session_entry="$(console_session_entry || true)"
  if [[ -z "$session_entry" ]]; then
    echo "  console session: unavailable"
    record_issue "Desktop session state is unavailable"
    return
  fi

  session_user="$(sed -n 's/.*kCGSSessionUserNameKey"="\([^"]*\)".*/\1/p' <<<"$session_entry")"
  if [[ -n "$session_user" ]]; then
    echo "  console user: $session_user"
  else
    echo "  console user: unknown"
  fi

  if grep -q '"CGSSessionScreenIsLocked"=Yes' <<<"$session_entry"; then
    echo "  screen: locked"
    record_issue "Desktop session is locked; unlock before target-app QA"
  elif grep -q '"kCGSessionLoginDoneKey"=Yes' <<<"$session_entry"; then
    echo "  screen: unlocked"
  else
    echo "  screen: unknown"
    record_issue "Desktop screen-lock state is unavailable"
  fi
}

echo "==> My Own Voice QA status"
echo "    Workspace: $ROOT_DIR"

echo
echo "==> Desktop session"
print_desktop_session_state

echo
echo "==> Target app availability"
find_app "Notes" "Notes.app" --bundle-id "com.apple.Notes"
find_app "Chrome" "Google Chrome.app" "Chrome.app" --bundle-id "com.google.Chrome"
find_app "Slack" "Slack.app" --bundle-id "com.tinyspeck.slackmacgap"
find_app "VS Code" "Visual Studio Code.app" "Code.app" --bundle-id "com.microsoft.VSCode" "com.microsoft.VSCodeInsiders"

echo
echo "==> Running app processes"
print_process_state "MyOwnVoiceApp"
print_process_state "MyOwnVoiceDev"

echo
echo "==> Local transcription runtime"
print_transcription_runtime_state

echo
echo "==> Permission probes"
echo "FocusedInsertionProbe:"
permission_output="$(run_focused_insertion_permission_check)"
printf "%s\n" "$permission_output"
if ! grep -q '^accessibilityTrusted=true$' <<<"$permission_output"; then
  record_issue "FocusedInsertionProbe is not trusted for Accessibility"
  if grep -q '^probeBinary=' <<<"$permission_output"; then
    echo "note=Enable the printed probeBinary entry in System Settings > Privacy & Security > Accessibility."
  fi
fi

echo
echo "MyOwnVoiceApp:"
if app_permission_output="$(run_app_permission_check)"; then
  printf "%s\n" "$app_permission_output"
else
  printf "%s\n" "$app_permission_output"
  record_issue "MyOwnVoiceApp permission state is unavailable"
fi
if ! grep -q '^myOwnVoiceAppMicrophoneAuthorization=authorized$' <<<"$app_permission_output"; then
  record_issue "MyOwnVoiceApp microphone authorization is not granted"
fi
if ! grep -q '^myOwnVoiceAppAccessibilityTrusted=true$' <<<"$app_permission_output"; then
  record_issue "MyOwnVoiceApp is not trusted for Accessibility"
  echo "note=Enable the My Own Voice app entry in System Settings > Privacy & Security > Accessibility."
fi
if grep -q '^myOwnVoiceAppFrontmostTarget=.*com[.]apple[.]loginwindow' <<<"$app_permission_output"; then
  record_issue "Desktop focus is currently loginwindow; unlock or focus a real text app before target-app QA"
  echo "note=Desktop focus is currently loginwindow, so target-app insertion labels cannot be trusted yet."
fi

echo
echo "==> Next manual QA steps"
echo "  1. Run ./script/verify_core_loop.sh for automated gates."
echo "  2. If screen is locked, unlock the desktop before granting permissions or counting target-app QA."
echo "  3. If Accessibility is missing, run ./script/request_accessibility.sh, enable FocusedInsertionProbe and My Own Voice, then rerun this check."
echo "  4. If myOwnVoiceAppFrontmostTarget is loginwindow, focus a real target text field before counting insertion QA."
echo "  5. Use Settings > Recording > Insertion Probe for app-owned target checks."
echo "  6. Use MY_OWN_VOICE_PROBE_PROCESS=app ./script/probe_focused_insertion.sh \"my own voice app insertion probe\" for app-bundle static checks."
echo "  7. Use ./script/probe_focused_insertion.sh \"my own voice insertion probe new line second line\" for helper CLI insertion checks."
echo "  8. Record results in docs/core-loop-qa.md and update docs/goal-completion-audit.md."

if [[ "$STRICT" == true ]]; then
  echo
  if [[ "${#qa_issues[@]}" -gt 0 ]]; then
    echo "==> Strict readiness: blocked"
    for issue in "${qa_issues[@]}"; do
      echo "  - $issue"
    done
    exit 1
  fi

  echo "==> Strict readiness: passed"
fi
