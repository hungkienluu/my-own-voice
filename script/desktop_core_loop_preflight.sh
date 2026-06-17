#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUTPUT_PATH="$ROOT_DIR/docs/audits/desktop-core-loop-preflight-$TIMESTAMP.md"
MANUAL_TEMPLATE_PATH="$ROOT_DIR/docs/audits/manual-evidence-$TIMESTAMP.md"

usage() {
  cat <<EOF
usage: $0 [--output path] [--manual-template path]

Runs the normal-desktop preflight for the My Own Voice core-loop QA pass and
writes a Markdown report with command output and next manual evidence steps.
Run this from a regular macOS desktop shell, not from Codex's sandbox.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      if [[ "$#" -lt 2 ]]; then
        echo "--output requires a path" >&2
        exit 2
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --manual-template)
      if [[ "$#" -lt 2 ]]; then
        echo "--manual-template requires a path" >&2
        exit 2
      fi
      MANUAL_TEMPLATE_PATH="$2"
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

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OUTPUT_PATH")" "$(dirname "$MANUAL_TEMPLATE_PATH")"

run_and_capture() {
  local title="$1"
  shift
  local status=0
  local output

  if output="$("$@" 2>&1)"; then
    status=0
  else
    status="$?"
  fi

  {
    echo "## $title"
    echo
    echo '```text'
    printf "%s\n" "$output"
    echo "exit=$status"
    echo '```'
    echo
  } >> "$OUTPUT_PATH"

  return "$status"
}

cat > "$OUTPUT_PATH" <<EOF
# Desktop Core Loop Preflight

Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')
Workspace: $ROOT_DIR
Manual evidence template: $MANUAL_TEMPLATE_PATH

Run the live target-app QA after this preflight passes, then fill the manual evidence template and validate it with:

\`\`\`bash
./script/core_loop_completion_audit.sh --run-verify --manual-evidence "$MANUAL_TEMPLATE_PATH"
\`\`\`

EOF

verify_status=0
build_status=0
strict_status=0
local_asr_status=0
template_status=0

run_and_capture "Automated Core Loop Gate" ./script/verify_core_loop.sh || verify_status="$?"
run_and_capture "Release Build And Relaunch" ./script/build_and_run.sh --release --verify || build_status="$?"
run_and_capture "Strict Readiness" ./script/qa_status.sh --strict || strict_status="$?"
run_and_capture "Local Transcription Smoke" ./script/local_transcription_smoke.sh || local_asr_status="$?"
run_and_capture "Manual Evidence Template" ./script/core_loop_completion_audit.sh --write-manual-template "$MANUAL_TEMPLATE_PATH" || template_status="$?"

cat >> "$OUTPUT_PATH" <<EOF
## Result

| Check | Exit |
| --- | --- |
| Automated core-loop gate | $verify_status |
| Release build and relaunch | $build_status |
| Strict readiness | $strict_status |
| Local transcription smoke | $local_asr_status |
| Manual evidence template | $template_status |

EOF

if [[ "$verify_status" == "0" && "$build_status" == "0" && "$strict_status" == "0" && "$local_asr_status" == "0" && "$template_status" == "0" ]]; then
  cat >> "$OUTPUT_PATH" <<EOF
Preflight result: PASS

Next: fill the target-app dictation, hotkey, feedback, recovery, and long-session rows in:

\`\`\`text
$MANUAL_TEMPLATE_PATH
\`\`\`
EOF
  echo "Wrote $OUTPUT_PATH"
  echo "Wrote $MANUAL_TEMPLATE_PATH"
  exit 0
fi

cat >> "$OUTPUT_PATH" <<EOF
Preflight result: BLOCKED

Fix the nonzero command outputs above before counting final target-app QA.
EOF

echo "Wrote $OUTPUT_PATH"
if [[ "$template_status" == "0" ]]; then
  echo "Wrote $MANUAL_TEMPLATE_PATH"
else
  echo "Manual evidence template was not written successfully; see $OUTPUT_PATH" >&2
fi
exit 1
