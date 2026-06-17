#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEXT="${MY_OWN_VOICE_CLIPBOARD_SMOKE_TEXT:-my own voice clipboard recovery smoke $(date +%s)-$$}"

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

run_focused_insertion_probe() {
  local probe_binary

  if probe_binary="$(focused_insertion_probe_binary)" && [[ -n "$probe_binary" ]]; then
    "$probe_binary" "$@"
  else
    swift run "${SWIFTPM_COMMON_ARGS[@]}" --quiet FocusedInsertionProbe "$@"
  fi
}

permissions_output="$(run_focused_insertion_probe --check-permissions)"
printf "%s\n" "$permissions_output"

empty_probe_output="$(run_focused_insertion_probe --restore-clipboard --empty-text --verify-delay 0)"
printf "%s\n" "$empty_probe_output"

if ! grep -q '^outcome=failed$' <<<"$empty_probe_output"; then
  echo "Clipboard recovery smoke failed: expected empty transcript insertion to fail safely." >&2
  exit 1
fi

if ! grep -q '^clipboardMatchesPreProbe=true$' <<<"$empty_probe_output"; then
  echo "Clipboard recovery smoke failed: empty transcript insertion changed the pre-probe pasteboard." >&2
  exit 1
fi

if ! grep -q '^clipboardRestored=true$' <<<"$empty_probe_output"; then
  echo "Clipboard recovery smoke failed: pre-probe pasteboard was not restored after empty transcript probe." >&2
  exit 1
fi

space_probe_output="$(run_focused_insertion_probe --restore-clipboard --verify-delay 0 $' \t ')"
printf "%s\n" "$space_probe_output"

if ! grep -q '^outcome=failed$' <<<"$space_probe_output"; then
  echo "Clipboard recovery smoke failed: expected whitespace-only transcript insertion to fail safely." >&2
  exit 1
fi

if ! grep -q '^clipboardMatchesPreProbe=true$' <<<"$space_probe_output"; then
  echo "Clipboard recovery smoke failed: whitespace-only transcript insertion changed the pre-probe pasteboard." >&2
  exit 1
fi

if ! grep -q '^clipboardRestored=true$' <<<"$space_probe_output"; then
  echo "Clipboard recovery smoke failed: pre-probe pasteboard was not restored after whitespace-only transcript probe." >&2
  exit 1
fi

if grep -q '^accessibilityTrusted=true$' <<<"$permissions_output"; then
  echo "Clipboard recovery smoke skipped: FocusedInsertionProbe has Accessibility trust, so this noninteractive check will not force the denied-permission fallback."
  exit 77
fi

probe_output="$(run_focused_insertion_probe --restore-clipboard --verify-delay 0 "$TEXT")"
printf "%s\n" "$probe_output"

if ! grep -q '^outcome=failed$' <<<"$probe_output"; then
  echo "Clipboard recovery smoke failed: expected outcome=failed when Accessibility is denied." >&2
  exit 1
fi

if ! grep -q '^clipboardMatchesProbe=true$' <<<"$probe_output"; then
  if grep -q '^clipboardMatchesPreProbe=true$' <<<"$probe_output" &&
    grep -q '^target=unknown$' <<<"$probe_output"; then
    echo "Clipboard recovery smoke skipped: system pasteboard or frontmost-app metadata is unavailable in this sandbox."
    exit 77
  fi

  echo "Clipboard recovery smoke failed: probe text was not left on the clipboard for recovery." >&2
  exit 1
fi

if ! grep -q '^clipboardRestored=true$' <<<"$probe_output"; then
  echo "Clipboard recovery smoke failed: pre-probe pasteboard was not restored." >&2
  exit 1
fi

echo "result=PASS"
