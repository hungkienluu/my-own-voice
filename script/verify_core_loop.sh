#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MyOwnVoiceApp"

cd "$ROOT_DIR"
source "$ROOT_DIR/script/swiftpm_env.sh"

echo "==> Checking script syntax"
bash -n \
  script/build_and_run.sh \
  script/build_installer.sh \
  script/clipboard_recovery_smoke.sh \
  script/core_loop_completion_audit.sh \
  script/desktop_core_loop_preflight.sh \
  script/dev_launch_smoke.sh \
  script/local_transcription_smoke.sh \
  script/probe_focused_insertion.sh \
  script/qa_status.sh \
  script/request_accessibility.sh \
  script/swiftpm_env.sh \
  script/verify_core_loop.sh

echo "==> Running AppCore self-checks"
swift run "${SWIFTPM_COMMON_ARGS[@]}" AppCoreSelfChecks

echo "==> Running completion-audit evidence gate self-test"
./script/core_loop_completion_audit.sh --self-test

echo "==> Building $APP_NAME"
swift build "${SWIFTPM_COMMON_ARGS[@]}" --product "$APP_NAME"

echo "==> Building $APP_NAME in release mode"
swift build "${SWIFTPM_COMMON_ARGS[@]}" -c release --product "$APP_NAME"

echo "==> Building focused insertion probe"
swift build "${SWIFTPM_COMMON_ARGS[@]}" --product FocusedInsertionProbe

echo "==> Running clipboard recovery smoke"
if ./script/clipboard_recovery_smoke.sh; then
  :
else
  smoke_status=$?
  if [[ "$smoke_status" == "77" ]]; then
    echo "==> Clipboard recovery smoke skipped; use manual target-app recovery QA when desktop permissions are available."
  else
    exit "$smoke_status"
  fi
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Running app-owned insertion recovery smoke"
  app_probe_output="$(
    MY_OWN_VOICE_PROBE_PROCESS=app \
      MY_OWN_VOICE_PROBE_DELAY_SECONDS=0 \
      MY_OWN_VOICE_PROBE_VERIFY_DELAY_SECONDS=0 \
      MY_OWN_VOICE_PROBE_RESTORE_CLIPBOARD=true \
      ./script/probe_focused_insertion.sh "my own voice app recovery smoke" 2>&1
  )"
  printf "%s\n" "$app_probe_output"

  if grep -q '^myOwnVoiceAppAccessibilityTrusted=false$' <<<"$app_probe_output"; then
    if ! grep -q '^outcome=failed$' <<<"$app_probe_output"; then
      echo "App-owned insertion recovery smoke failed: expected denied Accessibility to fail safely." >&2
      exit 1
    fi
    if ! grep -q '^clipboardMatchesProbe=true$' <<<"$app_probe_output"; then
      echo "App-owned insertion recovery smoke failed: app probe text was not left on the clipboard for recovery." >&2
      exit 1
    fi
    if ! grep -q '^clipboardRestored=true$' <<<"$app_probe_output"; then
      echo "App-owned insertion recovery smoke failed: pre-probe pasteboard was not restored." >&2
      exit 1
    fi
    echo "result=PASS"
  else
    echo "==> App-owned denied-Accessibility recovery smoke skipped because MyOwnVoiceApp has Accessibility trust."
  fi
else
  echo "==> App-owned insertion recovery smoke skipped because $APP_NAME is not running."
fi

echo "==> Running local transcription smoke"
if ./script/local_transcription_smoke.sh; then
  :
else
  smoke_status=$?
  if [[ "$smoke_status" == "77" ]]; then
    echo "==> Local transcription smoke skipped because local ASR smoke evidence is unavailable in this environment."
  else
    exit "$smoke_status"
  fi
fi

echo "==> Checking diff whitespace"
git diff --check

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> $APP_NAME is already running; using isolated release dev launch smoke instead of interrupting it."
  MY_OWN_VOICE_DEV_SAMPLE_SECONDS="${MY_OWN_VOICE_DEV_SAMPLE_SECONDS:-3}" ./script/dev_launch_smoke.sh --release
  echo "    Run ./script/build_and_run.sh --release --verify when it is safe to stop and relaunch the app."
else
  pgrep_status=$?
  if [[ "$pgrep_status" -gt 1 ]]; then
    echo "==> Process list is unavailable; skipping launch-state-dependent smoke."
    echo "    Run ./script/build_and_run.sh --release --verify in a normal desktop session for a bundle launch smoke test."
  else
    echo "==> $APP_NAME is not currently running."
    echo "    Run ./script/build_and_run.sh --release --verify for a bundle launch smoke test."
  fi
fi

echo "==> Automated core-loop gates passed."
echo "==> Manual real-app QA checklist: docs/core-loop-qa.md"
