#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_VERIFY=false
OUTPUT_PATH=""
MANUAL_EVIDENCE_PATH=""
WRITE_MANUAL_TEMPLATE_PATH=""
SELF_TEST=false

usage() {
  cat <<EOF
usage: $0 [--run-verify] [--manual-evidence path] [--write-manual-template path] [--output path] [--self-test]

Writes a Markdown completion-audit report for the current My Own Voice core-loop goal.
Use --run-verify when you want this command to rerun ./script/verify_core_loop.sh first.
Use --manual-evidence after filling a real-app QA report for Notes, Chrome, Slack, and VS Code.
Use --write-manual-template to create a fillable real-app QA evidence file.
Use --self-test to verify the manual-evidence gate rejects incomplete evidence and accepts complete evidence.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --run-verify)
      RUN_VERIFY=true
      shift
      ;;
    --manual-evidence)
      if [[ "$#" -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      MANUAL_EVIDENCE_PATH="$2"
      shift 2
      ;;
    --write-manual-template)
      if [[ "$#" -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      WRITE_MANUAL_TEMPLATE_PATH="$2"
      shift 2
      ;;
    --output)
      if [[ "$#" -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --self-test)
      SELF_TEST=true
      shift
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

cd "$ROOT_DIR"

write_manual_template() {
  local template_path="$1"
  local include_status_snapshot="${2:-true}"
  local template_status_output
  local template_strict_output
  local template_strict_exit=0

  mkdir -p "$(dirname "$template_path")"

  if [[ "$include_status_snapshot" == true ]]; then
    if ! template_status_output="$(./script/qa_status.sh 2>&1)"; then
      template_status_output="qa_status.sh failed while writing the manual template."
    fi

    if template_strict_output="$(./script/qa_status.sh --strict 2>&1)"; then
      template_strict_exit=0
    else
      template_strict_exit="$?"
    fi
  else
    template_status_output="Skipped during manual-evidence gate self-test."
    template_strict_output="Skipped during manual-evidence gate self-test."
    template_strict_exit="skipped"
  fi

  {
    echo "# My Own Voice Manual QA Evidence"
    echo
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo
    echo "Fill every \`TBD\` before passing this file to \`./script/core_loop_completion_audit.sh --manual-evidence\`."
    echo "Each required result cell must include \`PASS\` plus concrete evidence."
    echo "The target app rows must include the History target bundle IDs: \`com.apple.Notes\`, \`com.google.Chrome\`, \`com.tinyspeck.slackmacgap\`, and \`com.microsoft.VSCode\` or \`com.microsoft.VSCodeInsiders\`."
    echo "Each target app row must also describe the dictated-text outcome and the History/clipboard recovery evidence."
    echo "The preflight readiness snapshot must show \`screen: unlocked\`, \`accessibilityTrusted=true\`, \`myOwnVoiceAppMicrophoneAuthorization=authorized\`, \`myOwnVoiceAppAccessibilityTrusted=true\`, a non-loginwindow \`myOwnVoiceAppFrontmostTarget\`, and \`strict_exit=0\` before direct insertion QA can count as app-owned evidence."
    echo "The latency, long-session, active-manifest recovery, and idle-health rows must include a measured time, chunk filename/count evidence, manifest/chunk evidence, and numeric CPU/RSS values respectively."
    echo
    echo "## Desktop QA Runbook"
    echo
    echo "Run this sequence from a normal macOS desktop shell, not from Codex's sandbox, before filling the tables below:"
    echo
    echo '```bash'
    echo "./script/desktop_core_loop_preflight.sh"
    echo "MY_OWN_VOICE_PROBE_PROCESS=app MY_OWN_VOICE_PROBE_RESTORE_CLIPBOARD=true ./script/probe_focused_insertion.sh \"my own voice app insertion probe\""
    echo "./script/probe_focused_insertion.sh \"my own voice insertion probe new line second line\""
    echo '```'
    echo
    echo "For each target-app row, focus the named editable field, run an app-owned static probe if useful, then perform at least one live microphone dictation using the configured hold-to-talk or toggle shortcut. Record the visible text outcome and the app History target label. For Slack, keep the message unsent."
    echo
    echo "## Preflight Readiness Snapshot"
    echo
    echo "Captured when this template was generated. Replace it with a fresh snapshot if apps, permissions, or the running app process change before final QA."
    echo "Do not append a newer passing snapshot below an older blocked one; the evidence gate rejects stale \`strict_exit=1\`, locked-screen, denied-permission, or \`loginwindow\` markers anywhere in this file."
    echo
    echo "### ./script/qa_status.sh"
    echo
    echo '```text'
    printf "%s\n" "$template_status_output"
    echo '```'
    echo
    echo "### ./script/qa_status.sh --strict"
    echo
    echo '```text'
    printf "%s\n" "$template_strict_output"
    echo "strict_exit=${template_strict_exit}"
    echo '```'
    echo
    echo "## Target App Dictation"
    echo
    echo "| Target | Availability | Field | Voice dictation result | Insertion target label | Recovery evidence | Pass/Fail |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    echo "| Notes | TBD - installed app path | New note body | TBD - dictated text appeared/visible or fallback text stayed recoverable | TBD - Target: Notes (com.apple.Notes) | TBD - History row and clipboard recovery evidence | PASS - TBD |"
    echo "| Chrome | TBD - installed app path | Address bar or web text box | TBD - dictated text appeared/visible or fallback text stayed recoverable | TBD - Target: Google Chrome (com.google.Chrome) | TBD - History row and clipboard recovery evidence | PASS - TBD |"
    echo "| Slack | TBD - installed app path | Message compose field | TBD - dictated text appeared/visible without sending | TBD - Target: Slack (com.tinyspeck.slackmacgap) | TBD - History row and clipboard recovery evidence | PASS - TBD |"
    echo "| VS Code | TBD - installed app path | Untitled editor | TBD - dictated text appeared/visible at cursor | TBD - Target: Visual Studio Code (com.microsoft.VSCode or com.microsoft.VSCodeInsiders) | TBD - History row and clipboard recovery evidence | PASS - TBD |"
    echo
    echo "## Core Loop Behavior"
    echo
    echo "| Check | Required Evidence | Result |"
    echo "| --- | --- | --- |"
    echo "| Global hold-to-talk hotkey | Press starts recording, release stops, no shortcut conflict warning | PASS - TBD |"
    echo "| Toggle recording hotkey | Press starts, second press stops, mode is preserved during capture | PASS - TBD |"
    echo "| Recording feedback | Floating indicator visible while recording and hidden afterward | PASS - TBD |"
    echo "| Transcribing feedback | UI shows transcribing state until transcript is ready | PASS - TBD |"
    echo "| Local transcription latency | Short phrase inserts quickly enough for daily use without network-only dependency; include measured ms/s | PASS - TBD |"
    echo "| Cleanup and punctuation | Spoken punctuation and newline commands match the expected quick-dictation phrase | PASS - TBD |"
    echo
    echo "## Recovery And Long Session"
    echo
    echo "| Check | Required Evidence | Result |"
    echo "| --- | --- | --- |"
    echo "| Accessibility denied fallback | Transcript remains in History and on clipboard | PASS - TBD |"
    echo "| Clipboard fallback retry | History Insert succeeds or leaves recoverable clipboard text | PASS - TBD |"
    echo "| Delayed insertion verification | History updates when delayed field visibility confirms or rejects insertion | PASS - TBD |"
    echo "| Long session chunking | At least two chunks with increasing sequence prefixes and a capture manifest; include 0001-/0002- filenames or chunk count | PASS - TBD |"
    echo "| Active manifest recovery | Interrupted capture relaunches as retryable only when manifest and chunk files exist | PASS - TBD |"
    echo "| Idle health after relaunch | Fresh app process is below CPU/RSS thresholds in qa_status.sh --strict; include CPU and RSS values | PASS - TBD |"
  } > "$template_path"
}

row_has_pass_marker() {
  local evidence_path="$1"
  local row_label="$2"

  awk -F'|' -v row_label="$row_label" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }

    NF >= 3 {
      first_cell = trim($2)
      result_cell = trim($(NF - 1))
      if (first_cell == row_label && result_cell ~ /(^|[^[:alpha:]])PASS([^[:alpha:]]|$)/) {
        found = 1
      }
    }

    END {
      exit found ? 0 : 1
    }
  ' "$evidence_path"
}

row_contains_pattern() {
  local evidence_path="$1"
  local row_label="$2"
  local pattern="$3"

  awk -F'|' -v row_label="$row_label" -v pattern="$pattern" '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }

    NF >= 3 {
      first_cell = trim($2)
      result_cell = tolower(trim($(NF - 1)))
      row = tolower($0)
      search_text = result_cell
      if (first_cell == "Notes" || first_cell == "Chrome" || first_cell == "Slack" || first_cell == "VS Code") {
        search_text = row
      }
      if (first_cell == row_label && search_text ~ pattern) {
        found = 1
      }
    }

    END {
      exit found ? 0 : 1
    }
  ' "$evidence_path"
}

manual_evidence_has_incomplete_table_data() {
  local evidence_path="$1"

  awk -F'|' '
    function trim(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      return value
    }

    /^[[:space:]]*\|/ {
      first_cell = trim($2)
      if (first_cell == "---" || first_cell == "Target" || first_cell == "Check") {
        next
      }

      row = tolower($0)
      if (row ~ /(^|[[:space:]])(todo|tbd|not tested|not run|unavailable|missing|blocked|fail)([[:space:]]|$)/) {
        found = 1
      }
    }

    END {
      exit found ? 0 : 1
    }
  ' "$evidence_path"
}

manual_evidence_preflight_failures() {
  local evidence_path="$1"
  local failures=()

  if ! grep -Eq '^strict_exit=0$' "$evidence_path"; then
    failures+=("strict_exit=0")
  elif grep -Eq '^strict_exit=[1-9][0-9]*$' "$evidence_path"; then
    failures+=("no stale failing strict_exit snapshot")
  fi

  if ! grep -Eq '^accessibilityTrusted=true$' "$evidence_path"; then
    failures+=("FocusedInsertionProbe accessibilityTrusted=true")
  elif grep -Eq '^accessibilityTrusted=false$' "$evidence_path"; then
    failures+=("no stale FocusedInsertionProbe accessibilityTrusted=false snapshot")
  fi

  if ! grep -Eq '^[[:space:]]*screen: unlocked$' "$evidence_path"; then
    failures+=("screen: unlocked")
  elif grep -Eq '^[[:space:]]*screen: locked$' "$evidence_path"; then
    failures+=("no stale locked desktop session snapshot")
  fi

  if ! grep -Eq '^myOwnVoiceAppMicrophoneAuthorization=authorized$' "$evidence_path"; then
    failures+=("myOwnVoiceAppMicrophoneAuthorization=authorized")
  elif grep -Eq '^myOwnVoiceAppMicrophoneAuthorization=(denied|restricted|notDetermined|unknown)' "$evidence_path"; then
    failures+=("no stale MyOwnVoiceApp microphone denial snapshot")
  fi

  if ! grep -Eq '^myOwnVoiceAppAccessibilityTrusted=true$' "$evidence_path"; then
    failures+=("myOwnVoiceAppAccessibilityTrusted=true")
  elif grep -Eq '^myOwnVoiceAppAccessibilityTrusted=false$' "$evidence_path"; then
    failures+=("no stale MyOwnVoiceApp accessibility false snapshot")
  fi

  if ! grep -Eq '^myOwnVoiceAppFrontmostTarget=.+' "$evidence_path"; then
    failures+=("myOwnVoiceAppFrontmostTarget snapshot")
  elif grep -Eq '^myOwnVoiceAppFrontmostTarget=.*(loginwindow|com[.]apple[.]loginwindow)' "$evidence_path"; then
    failures+=("non-loginwindow myOwnVoiceAppFrontmostTarget")
  fi

  if [[ "${#failures[@]}" -gt 0 ]]; then
    printf "%s" "${failures[*]}"
    return 1
  fi
}

validate_manual_evidence() {
  local evidence_path="$1"
  local missing_pass_rows=()
  local missing_detail_rows=()
  local preflight_failures=""
  local required
  local index
  local required_pass_rows=(
    "Notes"
    "Chrome"
    "Slack"
    "VS Code"
    "Global hold-to-talk hotkey"
    "Toggle recording hotkey"
    "Recording feedback"
    "Transcribing feedback"
    "Local transcription latency"
    "Cleanup and punctuation"
    "Accessibility denied fallback"
    "Clipboard fallback retry"
    "Delayed insertion verification"
    "Long session chunking"
    "Active manifest recovery"
    "Idle health after relaunch"
  )
  local detail_labels=(
    "Notes"
    "Chrome"
    "Slack"
    "VS Code"
    "Notes"
    "Chrome"
    "Slack"
    "VS Code"
    "Notes"
    "Chrome"
    "Slack"
    "VS Code"
    "Local transcription latency"
    "Long session chunking"
    "Active manifest recovery"
    "Active manifest recovery"
    "Idle health after relaunch"
    "Idle health after relaunch"
  )
  local detail_patterns=(
    "com[.]apple[.]notes"
    "com[.]google[.]chrome"
    "com[.]tinyspeck[.]slackmacgap"
    "com[.]microsoft[.]vscode"
    "(dictat|insert|appear|visible)"
    "(dictat|insert|appear|visible)"
    "(dictat|insert|appear|visible)"
    "(dictat|insert|appear|visible)"
    "(history|clipboard|recovery)"
    "(history|clipboard|recovery)"
    "(history|clipboard|recovery)"
    "(history|clipboard|recovery)"
    "[0-9]+([.][0-9]+)?[[:space:]]*(ms|s|sec|secs|second|seconds)"
    "(0001-.*0002-|0002-.*0001-|[2-9][0-9]*[[:space:]]+chunks|two[[:space:]]+chunks)"
    "manifest"
    "(chunk|caf)"
    "cpu[^0-9|]*[0-9]+([.][0-9]+)?[[:space:]]*%"
    "rss[^0-9|]*[0-9]+([.][0-9]+)?[[:space:]]*(k|kb|m|mb|g|gb)"
  )
  local detail_descriptions=(
    "expected target label com.apple.Notes"
    "expected target label com.google.Chrome"
    "expected target label com.tinyspeck.slackmacgap"
    "expected target label com.microsoft.VSCode or com.microsoft.VSCodeInsiders"
    "expected dictated text insertion/visibility outcome"
    "expected dictated text insertion/visibility outcome"
    "expected dictated text insertion/visibility outcome"
    "expected dictated text insertion/visibility outcome"
    "expected History or clipboard recovery evidence"
    "expected History or clipboard recovery evidence"
    "expected History or clipboard recovery evidence"
    "expected History or clipboard recovery evidence"
    "expected measured latency such as 850ms or 1.2s"
    "expected chunk evidence such as 0001-/0002- filenames or 2+ chunks"
    "expected capture manifest evidence"
    "expected chunk or .caf evidence"
    "expected measured idle CPU percentage"
    "expected measured idle RSS value"
  )

  manual_evidence_exit=1

  if [[ ! -f "$evidence_path" ]]; then
    manual_evidence_status="missing"
    manual_evidence_output="Manual evidence file not found: $evidence_path"
  elif ! preflight_failures="$(manual_evidence_preflight_failures "$evidence_path")"; then
    manual_evidence_status="incomplete"
    manual_evidence_output="Manual evidence file preflight snapshot is not completion-ready: ${preflight_failures}"
  elif manual_evidence_has_incomplete_table_data "$evidence_path"; then
    manual_evidence_status="incomplete"
    manual_evidence_output="Manual evidence file contains incomplete/failing table-row language: $evidence_path"
  elif grep -Eq '\|[[:space:]]*\|' "$evidence_path"; then
    manual_evidence_status="incomplete"
    manual_evidence_output="Manual evidence file still appears to contain blank Markdown table cells: $evidence_path"
  else
    for required in "${required_pass_rows[@]}"; do
      if ! row_has_pass_marker "$evidence_path" "$required"; then
        missing_pass_rows+=("$required")
      fi
    done

    if [[ "${#missing_pass_rows[@]}" -gt 0 ]]; then
      manual_evidence_status="incomplete"
      manual_evidence_output="Manual evidence file is missing PASS evidence for required rows: ${missing_pass_rows[*]}"
    else
      for index in "${!detail_labels[@]}"; do
        if ! row_contains_pattern "$evidence_path" "${detail_labels[$index]}" "${detail_patterns[$index]}"; then
          missing_detail_rows+=("${detail_labels[$index]} (${detail_descriptions[$index]})")
        fi
      done

      if [[ "${#missing_detail_rows[@]}" -gt 0 ]]; then
        manual_evidence_status="incomplete"
        manual_evidence_output="Manual evidence file is missing concrete detail for required rows: ${missing_detail_rows[*]}"
      else
        manual_evidence_exit=0
        manual_evidence_status="provided"
        manual_evidence_output="Manual evidence file passed structural PASS and concrete-detail checks: $evidence_path"
      fi
    fi
  fi
}

completion_gate_passes() {
  local strict_result="$1"
  local verify_result="$2"
  local manual_result="$3"

  [[ "$strict_result" == "0" && "$verify_result" == "0" && "$manual_result" == "0" ]]
}

write_complete_manual_evidence_fixture() {
  local evidence_path="$1"

  cat >"$evidence_path" <<'EOF'
# My Own Voice Manual QA Evidence

## Preflight Readiness Snapshot

```text
==> Desktop session
  console user: exampleuser
  screen: unlocked

FocusedInsertionProbe:
accessibilityTrusted=true

MyOwnVoiceApp:
myOwnVoiceAppMicrophoneAuthorization=authorized
myOwnVoiceAppAccessibilityTrusted=true
myOwnVoiceAppFrontmostTarget=Notes (com.apple.Notes)

==> Strict readiness: ready
strict_exit=0
```

## Target App Dictation

| Target | Availability | Field | Voice dictation result | Insertion target label | Recovery evidence | Pass/Fail |
| --- | --- | --- | --- | --- | --- | --- |
| Notes | Installed at /System/Applications/Notes.app | New note body | PASS - dictated phrase appeared with punctuation and line breaks | Target: Notes (com.apple.Notes) | PASS - History retained transcript and clipboard recovery text was present | PASS - Notes evidence recorded |
| Chrome | Installed at /Applications/Google Chrome.app | Address bar text field | PASS - dictated phrase appeared or recovery text stayed available | Target: Google Chrome (com.google.Chrome) | PASS - History retained transcript and clipboard recovery text was present | PASS - Chrome evidence recorded |
| Slack | Installed at /Applications/Slack.app | Message compose field | PASS - dictated phrase appeared in compose field without sending | Target: Slack (com.tinyspeck.slackmacgap) | PASS - History retained transcript and clipboard recovery text was present | PASS - Slack evidence recorded |
| VS Code | Installed at /Applications/Visual Studio Code.app | Untitled editor | PASS - dictated phrase appeared at cursor with line breaks | Target: Visual Studio Code (com.microsoft.VSCode) | PASS - History retained transcript and clipboard recovery text was present | PASS - VS Code evidence recorded |

## Core Loop Behavior

| Check | Required Evidence | Result |
| --- | --- | --- |
| Global hold-to-talk hotkey | Press starts recording, release stops, no shortcut conflict warning | PASS - press and release behavior recorded |
| Toggle recording hotkey | Press starts, second press stops, mode is preserved during capture | PASS - toggle behavior recorded |
| Recording feedback | Floating indicator visible while recording and hidden afterward | PASS - visual recording state recorded |
| Transcribing feedback | UI shows transcribing state until transcript is ready | PASS - visual transcribing state recorded |
| Local transcription latency | Short phrase inserts quickly enough for daily use without network-only dependency | PASS - local microphone phrase inserted in 1.2s |
| Cleanup and punctuation | Spoken punctuation and newline commands match the expected quick-dictation phrase | PASS - punctuation phrase recorded |

## Recovery And Long Session

| Check | Required Evidence | Result |
| --- | --- | --- |
| Accessibility denied fallback | Transcript remains in History and on clipboard | PASS - denied-permission recovery recorded |
| Clipboard fallback retry | History Insert succeeds or leaves recoverable clipboard text | PASS - retry recovery recorded |
| Delayed insertion verification | History updates when delayed field visibility confirms or rejects insertion | PASS - delayed verification recorded |
| Long session chunking | At least two chunks with increasing sequence prefixes and a capture manifest | PASS - capture-manifest.json with 0001-audio.caf and 0002-audio.caf recorded |
| Active manifest recovery | Interrupted capture relaunches as retryable only when manifest and chunk files exist | PASS - capture-manifest.json and 0001-audio.caf recovery evidence recorded |
| Idle health after relaunch | Fresh app process is below CPU/RSS thresholds in qa_status.sh --strict | PASS - qa_status.sh --strict showed CPU 1.0% and RSS 145.0M |
EOF
}

run_self_test() {
  local temp_root
  local template_path
  local missing_row_path
  local insiders_path
  local weak_target_path
  local weak_recovery_path
  local weak_idle_path
  local blocked_preflight_path
  local stale_preflight_path
  local complete_body_path
  local complete_with_instruction_path
  local complete_path

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/my-own-voice-audit-self-test.XXXXXX")"
  trap 'rm -rf "$temp_root"' RETURN

  template_path="$temp_root/template.md"
  missing_row_path="$temp_root/missing-row.md"
  insiders_path="$temp_root/insiders.md"
  weak_target_path="$temp_root/weak-target-row.md"
  weak_recovery_path="$temp_root/weak-recovery-row.md"
  weak_idle_path="$temp_root/weak-idle-row.md"
  blocked_preflight_path="$temp_root/blocked-preflight.md"
  stale_preflight_path="$temp_root/stale-preflight.md"
  complete_body_path="$temp_root/complete-body.md"
  complete_with_instruction_path="$temp_root/complete-with-instruction.md"
  complete_path="$temp_root/complete.md"

  write_manual_template "$template_path" false
  validate_manual_evidence "$template_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_status" != "incomplete" ]]; then
    echo "Self-test failed: template evidence should be rejected as incomplete." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$missing_row_path"
  grep -v '^| VS Code |' "$missing_row_path" >"$missing_row_path.tmp"
  mv "$missing_row_path.tmp" "$missing_row_path"
  validate_manual_evidence "$missing_row_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_output" != *"VS Code"* ]]; then
    echo "Self-test failed: evidence missing the VS Code row should be rejected." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$insiders_path"
  awk '
    /^\| VS Code \|/ {
      print "| VS Code | Installed at /Applications/Visual Studio Code - Insiders.app | Untitled editor | PASS - dictated phrase appeared at cursor with line breaks | Target: Visual Studio Code Insiders (com.microsoft.VSCodeInsiders) | PASS - History retained transcript and clipboard recovery text was present | PASS - VS Code Insiders evidence recorded |"
      next
    }
    { print }
  ' "$insiders_path" >"$insiders_path.tmp"
  mv "$insiders_path.tmp" "$insiders_path"
  validate_manual_evidence "$insiders_path"
  if [[ "$manual_evidence_exit" != "0" || "$manual_evidence_status" != "provided" ]]; then
    echo "Self-test failed: complete PASS evidence should accept VS Code Insiders bundle IDs." >&2
    echo "$manual_evidence_output" >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$weak_target_path"
  awk '
    /^\| Notes \|/ {
      print "| Notes | Installed at /System/Applications/Notes.app | New note body | PASS - evidence recorded | Target: Notes (com.apple.Notes) | PASS - evidence recorded | PASS - Notes evidence recorded |"
      next
    }
    { print }
  ' "$weak_target_path" >"$weak_target_path.tmp"
  mv "$weak_target_path.tmp" "$weak_target_path"
  validate_manual_evidence "$weak_target_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_output" != *"Notes"* ]]; then
    echo "Self-test failed: weak target-app evidence without insertion/recovery details should be rejected." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$weak_recovery_path"
  awk '
    /^\| Active manifest recovery \|/ {
      print "| Active manifest recovery | Interrupted capture relaunches as retryable only when manifest and chunk files exist | PASS - recovery evidence recorded |"
      next
    }
    { print }
  ' "$weak_recovery_path" >"$weak_recovery_path.tmp"
  mv "$weak_recovery_path.tmp" "$weak_recovery_path"
  validate_manual_evidence "$weak_recovery_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_output" != *"Active manifest recovery"* ]]; then
    echo "Self-test failed: active-manifest recovery evidence without manifest/chunk details should be rejected." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$weak_idle_path"
  awk '
    /^\| Idle health after relaunch \|/ {
      print "| Idle health after relaunch | Fresh app process is below CPU/RSS thresholds in qa_status.sh --strict | PASS - qa_status.sh --strict showed CPU and RSS below thresholds |"
      next
    }
    { print }
  ' "$weak_idle_path" >"$weak_idle_path.tmp"
  mv "$weak_idle_path.tmp" "$weak_idle_path"
  validate_manual_evidence "$weak_idle_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_output" != *"Idle health after relaunch"* ]]; then
    echo "Self-test failed: idle health evidence without numeric CPU/RSS values should be rejected." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$blocked_preflight_path"
  awk '
    /^accessibilityTrusted=true$/ {
      print "accessibilityTrusted=false"
      next
    }
    /^[[:space:]]*screen: unlocked$/ {
      print "  screen: locked"
      next
    }
    /^myOwnVoiceAppAccessibilityTrusted=true$/ {
      print "myOwnVoiceAppAccessibilityTrusted=false"
      next
    }
    /^myOwnVoiceAppFrontmostTarget=/ {
      print "myOwnVoiceAppFrontmostTarget=loginwindow (com.apple.loginwindow)"
      next
    }
    /^strict_exit=0$/ {
      print "strict_exit=1"
      next
    }
    { print }
  ' "$blocked_preflight_path" >"$blocked_preflight_path.tmp"
  mv "$blocked_preflight_path.tmp" "$blocked_preflight_path"
  validate_manual_evidence "$blocked_preflight_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_output" != *"preflight"* ]]; then
    echo "Self-test failed: structurally complete evidence with blocked preflight should be rejected." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$stale_preflight_path"
  {
    cat <<'EOF'
```text
==> Desktop session
  console user: exampleuser
  screen: locked

FocusedInsertionProbe:
accessibilityTrusted=false

MyOwnVoiceApp:
myOwnVoiceAppMicrophoneAuthorization=denied
myOwnVoiceAppAccessibilityTrusted=false
myOwnVoiceAppFrontmostTarget=loginwindow (com.apple.loginwindow)

==> Strict readiness: blocked
strict_exit=1
```
EOF
    cat "$stale_preflight_path"
  } >"$stale_preflight_path.tmp"
  mv "$stale_preflight_path.tmp" "$stale_preflight_path"
  validate_manual_evidence "$stale_preflight_path"
  if [[ "$manual_evidence_exit" == "0" || "$manual_evidence_output" != *"stale"* ]]; then
    echo "Self-test failed: evidence with a passing snapshot plus stale blocked snapshot should be rejected." >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$complete_body_path"
  {
    echo "Fill every \`TBD\` before passing this file to the audit command."
    cat "$complete_body_path"
  } >"$complete_with_instruction_path"
  validate_manual_evidence "$complete_with_instruction_path"
  if [[ "$manual_evidence_exit" != "0" || "$manual_evidence_status" != "provided" ]]; then
    echo "Self-test failed: completed table evidence should not be rejected by instructional TBD prose." >&2
    echo "$manual_evidence_output" >&2
    return 1
  fi

  write_complete_manual_evidence_fixture "$complete_path"
  validate_manual_evidence "$complete_path"
  if [[ "$manual_evidence_exit" != "0" || "$manual_evidence_status" != "provided" ]]; then
    echo "Self-test failed: complete PASS evidence should be accepted." >&2
    echo "$manual_evidence_output" >&2
    return 1
  fi

  if completion_gate_passes 0 "not-run" 0; then
    echo "Self-test failed: completion gate should reject skipped automated verification." >&2
    return 1
  fi

  if completion_gate_passes 1 0 0; then
    echo "Self-test failed: completion gate should reject strict readiness failures." >&2
    return 1
  fi

  if completion_gate_passes 0 1 0; then
    echo "Self-test failed: completion gate should reject automated verification failures." >&2
    return 1
  fi

  if completion_gate_passes 0 0 1; then
    echo "Self-test failed: completion gate should reject incomplete manual evidence." >&2
    return 1
  fi

  if ! completion_gate_passes 0 0 0; then
    echo "Self-test failed: completion gate should accept all-green evidence." >&2
    return 1
  fi

  echo "Manual evidence gate self-test passed."
}

if [[ -n "$WRITE_MANUAL_TEMPLATE_PATH" ]]; then
  write_manual_template "$WRITE_MANUAL_TEMPLATE_PATH"
  echo "Wrote $WRITE_MANUAL_TEMPLATE_PATH"
  exit 0
fi

if [[ "$SELF_TEST" == true ]]; then
  run_self_test
  exit 0
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  OUTPUT_PATH="docs/audits/core-loop-completion-${timestamp}.md"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

status_output="$(./script/qa_status.sh)"
strict_output="$(./script/qa_status.sh --strict 2>&1)" || strict_exit="$?"
strict_exit="${strict_exit:-0}"
verify_exit="not-run"
verify_status="not run"
manual_evidence_exit=1
manual_evidence_status="not provided"
manual_evidence_output="No manual evidence file was provided. Create one with --write-manual-template docs/audits/my-filled-qa.md, run real-app QA, fill every TBD, then pass it with --manual-evidence path."

if [[ "$RUN_VERIFY" == true ]]; then
  if verify_output="$(./script/verify_core_loop.sh 2>&1)"; then
    verify_exit=0
    verify_status="passed"
  else
    verify_exit="$?"
    verify_status="failed with exit code ${verify_exit}"
  fi
else
  verify_output="Skipped. Re-run with --run-verify to refresh automated build/self-check evidence."
fi

if [[ -n "$MANUAL_EVIDENCE_PATH" ]]; then
  validate_manual_evidence "$MANUAL_EVIDENCE_PATH"
fi

{
  echo "# Core Loop Completion Audit"
  echo
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  echo "## Objective"
  echo
  echo "Make My Own Voice a daily-usable, local-first macOS dictation app that can replace keyboard typing for short and medium writing in real Mac apps."
  echo
  echo "## Success Criteria"
  echo
  echo "| Requirement | Evidence Source | Current Status |"
  echo "| --- | --- | --- |"
  echo "| Global hotkey starts/stops dictation | AppCore self-checks, manual hotkey QA in docs/core-loop-qa.md | Requires live app QA |"
  echo "| Hold-to-talk and toggle recording | AppCore self-checks, manual hotkey QA in docs/core-loop-qa.md | Requires live app QA |"
  echo "| Clear recording/transcribing feedback | Recording indicator code, active-status preservation self-checks, visual QA in docs/core-loop-qa.md | Requires relaunched app visual QA |"
  echo "| Low-latency local transcription | Local ASR readiness in qa_status.sh, ./script/local_transcription_smoke.sh, bounded chunk context, bounded WhisperKit/whisper.cpp prompt context, bounded local subprocess/runtime request timeouts with forced kill after the grace window, whisper.cpp temp-output cleanup after converter failure, live dictation timing | Automated synthetic-audio smoke, bounded chunk context, bounded ASR prompt context, bounded local runtime requests, subprocess timeout kill, and converter-failure temp cleanup covered when local whisper.cpp is ready; still requires live dictation QA |"
  echo "| Light cleanup/punctuation | AppCore self-checks | Automated local logic covered |"
  echo "| First-run app permissions | Status menu notices, Settings permission rows, MyOwnVoiceApp --check-permissions through qa_status.sh, FocusedInsertionProbe --check-permissions through qa_status.sh | App microphone authorization is checked; helper and app Accessibility trust still require macOS consent |"
  echo "| Reliable focused-field insertion | FocusedInsertionProbe, MyOwnVoiceApp app-owned probe mode, bounded local insertion observation anchors, saved-insertion live-capture guards, plus Notes/Chrome/Slack/VS Code matrix | Requires target app QA |"
  echo "| Clipboard/history recovery | AppCore self-checks, status-only recovery action gating, row-owned deferred cleanup guards including History-cap cancellation, idle-only History mutation guards, saved-insertion live-capture guards, ./script/clipboard_recovery_smoke.sh, FocusedInsertionProbe, MyOwnVoiceApp app-owned probe mode, History QA | Empty/whitespace transcript pasteboard preservation, denied-Accessibility clipboard recovery, app-owned denied-Accessibility recovery when MyOwnVoiceApp is running, deferred cleanup row ownership, History-cap row task cancellation, idle-only History mutation, saved-transcript action availability, and probe restore-delay coverage for async clipboard fallback covered; still requires target app recovery QA |"
  echo "| Stable long-session capture | AppCore self-checks including recoverable-manifest stress, non-empty chunk retry gating for recovered and fresh failed captures, status-only retry gating, bounded chunk context, bounded local cleanup, whisper.cpp temp-output cleanup after converter failure, subprocess timeout kill, row-owned deferred cleanup cancellation including History-cap cancellation, imported-audio setup cleanup, bounded insertion observation, and bounded post-paste learning, dev smoke footprint gate, long-session manual QA | Manifest/chunk stress, recovered-row action gating, non-empty chunk retry gating for recovered and fresh failed captures, bounded chunk context, bounded local cleanup, subprocess timeout kill, converter-failure temp cleanup, deferred cleanup cancellation/application guards, History-cap row task cancellation, imported-audio setup cleanup build coverage, bounded insertion observation, bounded background correction learning, and startup footprint covered; long-duration manual QA still required |"
  echo "| Dictation-first MVP scope | Code/doc review | Satisfied so far |"
  echo "| Preserve SwiftUI/AppKit architecture | Diff review | Satisfied so far |"
  echo "| Relevant Swift build/tests | ./script/verify_core_loop.sh | ${verify_status} |"
  echo "| Notes/Chrome/Slack/VS Code verification | qa_status.sh, docs/core-loop-qa.md, --manual-evidence | ${manual_evidence_status} |"
  echo
  cat <<'CHECKLIST'
## Prompt-To-Artifact Checklist

| Goal requirement | Concrete artifact or command | Coverage in this report |
| --- | --- | --- |
| Daily-usable local-first macOS dictation app | `Package.swift`, `Sources/MyOwnVoiceApp`, `Sources/AppCore`, local WhisperKit/whisper.cpp readiness from `./script/qa_status.sh`, app-owned permission snapshot from `MyOwnVoiceApp --check-permissions` | Implemented artifacts present; daily usability still requires real-app manual QA |
| Replace keyboard typing for short and medium writing in real Mac apps | `docs/core-loop-qa.md` real app insertion matrix plus `--manual-evidence` rows for Notes, Chrome, Slack, and VS Code | Not complete until every target row has concrete PASS evidence |
| Global hotkey core loop | `Sources/AppCore/HotkeyManager.swift`, `Sources/AppCore/DictationCoordinator.swift`, `AppCoreSelfChecks` through `./script/verify_core_loop.sh` | Automated shortcut validation, transactional registration fallback, duplicate regular hotkey-event suppression, and modifier-only local/global monitoring covered; live global shortcut behavior requires manual QA |
| Hold-to-talk recording | `handleHotkeyPress`/`handleHotkeyRelease` paths in `DictationCoordinator`, AppCore self-checks, manual evidence row `Global hold-to-talk hotkey` | Automated state logic and duplicate hotkey-event dispatch covered; physical key press/release requires manual QA |
| Toggle recording | `toggleRecordingFromHotkey` path in `DictationCoordinator`, AppCore self-checks, manual evidence row `Toggle recording hotkey` | Automated state logic and duplicate hotkey-event dispatch covered; physical toggle behavior requires manual QA |
| Recording and transcribing feedback | `Sources/MyOwnVoiceApp/RecordingIndicatorController.swift`, `StatusMenuView.swift`, active-status preservation in `DictationCoordinator`, manual evidence rows `Recording feedback` and `Transcribing feedback` | Implemented and build/self-check covered; visual behavior requires relaunched app QA |
| Low-latency local transcription | `Sources/AppCore/WhisperKitTranscriptionEngine.swift`, `LocalWhisperCPPTranscriptionEngine.swift`, `DictationCoordinator.boundedPreviousTranscriptContext`, bounded WhisperKit/whisper.cpp prompt context, whisper.cpp converter-failure temp cleanup, subprocess timeout kill, `OllamaService` request timeouts, `./script/local_transcription_smoke.sh`, `./script/qa_status.sh` | Synthetic local ASR smoke, bounded chunk context, bounded ASR prompt context, bounded Ollama requests, bounded local subprocess failure behavior, subprocess timeout kill, and converter-failure temp cleanup covered when prerequisites exist; live microphone/insertion timing still manual |
| Light cleanup and punctuation | `Sources/AppCore/TranscriptFormatting.swift`, `TranscriptCorrectionEngine.swift`, AppCore self-checks, manual evidence row `Cleanup and punctuation` | Automated local formatting covered; live dictated phrase still manual |
| Reliable focused-field insertion | `Sources/AppCore/FocusedTextInsertionService.swift`, `Tests/FocusedInsertionProbe`, `MyOwnVoiceApp --check-permissions` via `./script/qa_status.sh`, `MyOwnVoiceApp --probe-insertion` via `MY_OWN_VOICE_PROBE_PROCESS=app ./script/probe_focused_insertion.sh`, saved-transcript insertion guards, target-app matrix | Fallback smoke, app-owned permission snapshot/probe mode, bounded local-anchor visibility logic, live-capture insertion guards, and probe dependency freshness checks covered; direct insertion into Notes/Chrome/Slack/VS Code still manual |
| Clipboard/history recovery when insertion fails | `./script/clipboard_recovery_smoke.sh`, `FocusedInsertionProbe --restore-clipboard`, `MyOwnVoiceApp --probe-insertion --restore-clipboard`, `FocusedTextInsertionService.clipboardRestoreDelayAfterFallbackPaste`, `RecentTranscript` history logic, failed-capture retry-copy gating, status-only recovery action gating, row-owned deferred cleanup guards including History-cap cancellation, idle-only History mutation guards, saved-insertion live-capture guards, recovery rows in manual evidence | Empty/whitespace transcript pasteboard preservation, denied-Accessibility clipboard recovery, app-owned denied-Accessibility recovery when MyOwnVoiceApp is running, probe restore-delay coverage for async clipboard fallback, failed-capture retry copy, deferred cleanup row ownership, History-cap row task cancellation, idle-only History mutation, and saved-transcript action availability covered; History retry/recovery still manual in target apps |
| Stable long-session capture without runaway memory | `Sources/AppCore/AudioCaptureService.swift`, `Sources/AppCore/FocusedTextInsertionService.swift`, `Sources/AppCore/PostPasteCorrectionDetector.swift`, recoverable-manifest stress, non-empty chunk retry gating for recovered and fresh failed captures, status-only retry gating, bounded chunk context, bounded local cleanup, whisper.cpp converter-failure temp cleanup, subprocess timeout kill, row-owned deferred cleanup cancellation including History-cap cancellation, imported-audio setup cleanup, bounded insertion observation, and bounded post-paste learning in AppCore self-checks, `./script/dev_launch_smoke.sh` footprint gate, manual long-session rows | Manifest/chunk logic, large incomplete-session filtering, recovered-row action gating, non-empty chunk retry gating for recovered and fresh failed captures, bounded chunk context, bounded local cleanup, subprocess timeout kill, converter-failure temp cleanup, deferred cleanup cancellation/application guards, History-cap row task cancellation, imported-audio setup cleanup build coverage, bounded insertion observation, bounded background correction learning, and bounded launch footprint covered; long-duration capture memory still manual |
| Keep MVP focused on dictation first | `docs/core-loop-qa.md`, code/diff scope, separated meeting transcript service | Satisfied so far by scope review; no broad rewrite/sync/team feature evidence added |
| Defer meeting intelligence, sync, team features, advanced snippets, broad rewrite unless protective | Diff review and docs scope | Satisfied so far; audit should be rechecked if new feature scope is added |
| Preserve SwiftUI/AppKit architecture | `Sources/MyOwnVoiceApp` SwiftUI/AppKit views plus `Sources/AppCore` services | Satisfied so far by file ownership/diff review |
| Respect uncommitted user changes | `git status --short` before/after work; no destructive git commands | Requires human review of dirty worktree before staging/commit |
CHECKLIST
  echo "| Run relevant Swift build/tests when possible | \`./script/verify_core_loop.sh\`, AppCore self-checks, app/probe/smoke builds | ${verify_status} |"
  echo "| Verify Notes, Chrome/Slack text fields, and VS Code | \`./script/desktop_core_loop_preflight.sh\`, \`./script/qa_status.sh\`, \`docs/core-loop-qa.md\`, \`--manual-evidence\` with passing preflight snapshot | Not complete: app availability/readiness/manual evidence still required |"
  echo
  echo "## Completion Decision"
  echo
  if [[ "$strict_exit" == "0" && "$verify_exit" == "0" && "$manual_evidence_exit" == "0" ]]; then
    echo "Strict readiness, automated gates, and supplied manual evidence checks passed. Review the evidence contents before marking the goal complete."
  else
    echo "Not complete. Strict readiness, automated verification, or manual real-app QA evidence is not fully green."
  fi
  echo
  echo "## Manual Evidence Matrix"
  echo
  echo "Fill these rows during final QA. A blank or unavailable row is not completion evidence. Required result cells must include \`PASS\` plus concrete evidence."
  echo "The audit gate also requires target-app bundle IDs, dictated-text outcome details, History/clipboard recovery evidence, measured local transcription latency, long-session chunk evidence, active-manifest recovery manifest/chunk evidence, numeric idle CPU/RSS values, \`strict_exit=0\`, \`screen: unlocked\`, helper and app Accessibility trust, app microphone authorization, and a non-loginwindow frontmost target."
  echo
  echo "### Target App Dictation"
  echo
  echo "| Target | Availability | Field | Voice dictation result | Insertion target label | Recovery evidence | Pass/Fail |"
  echo "| --- | --- | --- | --- | --- | --- | --- |"
  echo "| Notes | From qa_status.sh | New note body |  |  |  |  |"
  echo "| Chrome | From qa_status.sh | Address bar or web text box |  |  |  |  |"
  echo "| Slack | From qa_status.sh | Message compose field |  |  |  |  |"
  echo "| VS Code | From qa_status.sh | Untitled editor |  |  |  |  |"
  echo
  echo "### Core Loop Behavior"
  echo
  echo "| Check | Required Evidence | Result |"
  echo "| --- | --- | --- |"
  echo "| Global hold-to-talk hotkey | Press starts recording, release stops, no shortcut conflict warning |  |"
  echo "| Toggle recording hotkey | Press starts, second press stops, mode is preserved during capture |  |"
  echo "| Recording feedback | Floating indicator visible while recording and hidden afterward |  |"
  echo "| Transcribing feedback | UI shows transcribing state until transcript is ready |  |"
  echo "| Local transcription latency | Short phrase inserts quickly enough for daily use without network-only dependency; include measured ms/s |  |"
  echo "| Cleanup and punctuation | Spoken punctuation and newline commands match the expected quick-dictation phrase |  |"
  echo
  echo "### Recovery And Long Session"
  echo
  echo "| Check | Required Evidence | Result |"
  echo "| --- | --- | --- |"
  echo "| Accessibility denied fallback | Transcript remains in History and on clipboard |  |"
  echo "| Clipboard fallback retry | History Insert succeeds or leaves recoverable clipboard text |  |"
  echo "| Delayed insertion verification | History updates when delayed field visibility confirms or rejects insertion |  |"
  echo "| Long session chunking | At least two chunks with increasing sequence prefixes and a capture manifest; include 0001-/0002- filenames or chunk count |  |"
  echo "| Active manifest recovery | Interrupted capture relaunches as retryable only when manifest and chunk files exist |  |"
  echo "| Idle health after relaunch | Fresh app process is below CPU/RSS thresholds in qa_status.sh --strict; include CPU and RSS values |  |"
  echo
  echo "## Manual Evidence Status"
  echo
  echo '```text'
  printf "%s\n" "$manual_evidence_output"
  echo "manual_evidence_exit=${manual_evidence_exit}"
  echo '```'
  echo
  echo "## QA Status"
  echo
  echo '```text'
  printf "%s\n" "$status_output"
  echo '```'
  echo
  echo "## Strict Readiness"
  echo
  echo '```text'
  printf "%s\n" "$strict_output"
  echo "strict_exit=${strict_exit}"
  echo '```'
  echo
  echo "## Automated Gate"
  echo
  echo '```text'
  printf "%s\n" "$verify_output"
  echo "verify_exit=${verify_exit}"
  echo '```'
} > "$OUTPUT_PATH"

echo "Wrote $OUTPUT_PATH"

if ! completion_gate_passes "$strict_exit" "$verify_exit" "$manual_evidence_exit"; then
  exit 1
fi
