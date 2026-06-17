#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_CLI="${MY_OWN_VOICE_WHISPER_CLI:-}"
WHISPER_MODEL="${MY_OWN_VOICE_WHISPER_MODEL:-$HOME/Library/Application Support/MyOwnVoice/Models/whisper/ggml-small.en.bin}"
WHISPER_ARGS=()

if [[ -z "$WHISPER_CLI" ]]; then
  if [[ -x /opt/homebrew/bin/whisper-cli ]]; then
    WHISPER_CLI=/opt/homebrew/bin/whisper-cli
  elif [[ -x /usr/local/bin/whisper-cli ]]; then
    WHISPER_CLI=/usr/local/bin/whisper-cli
  else
    echo "Local transcription smoke skipped: whisper-cli not found." >&2
    exit 77
  fi
fi

if [[ ! -x "$WHISPER_CLI" ]]; then
  echo "Local transcription smoke skipped: whisper-cli is not executable at $WHISPER_CLI." >&2
  exit 77
fi

if [[ ! -f "$WHISPER_MODEL" ]]; then
  echo "Local transcription smoke skipped: model file not found at $WHISPER_MODEL." >&2
  exit 77
fi

if [[ ! -x /usr/bin/say ]]; then
  echo "Local transcription smoke skipped: /usr/bin/say is unavailable." >&2
  exit 77
fi

cd "$ROOT_DIR"
source "$ROOT_DIR/script/swiftpm_env.sh"

if [[ "${MY_OWN_VOICE_WHISPER_NO_GPU:-false}" == true ]] || [[ -n "${CODEX_SANDBOX:-}" ]]; then
  WHISPER_ARGS+=(--whisper-arg --no-gpu)
fi

SMOKE_ARGS=(
  --whisper-cli "$WHISPER_CLI"
  --model-file "$WHISPER_MODEL"
)

if [[ ${#WHISPER_ARGS[@]} -gt 0 ]]; then
  SMOKE_ARGS+=("${WHISPER_ARGS[@]}")
fi

smoke_output="$(
  swift run "${SWIFTPM_COMMON_ARGS[@]}" LocalTranscriptionSmoke \
    "${SMOKE_ARGS[@]}" \
    "$@" 2>&1
)" || {
  smoke_status=$?
  printf "%s\n" "$smoke_output" >&2

  if [[ -n "${CODEX_SANDBOX:-}" ]] &&
    grep -q 'whisper-cli failed with exit code 11' <<<"$smoke_output"; then
    echo "Local transcription smoke skipped: whisper.cpp native backend crashed inside CODEX_SANDBOX=$CODEX_SANDBOX; rerun in a normal desktop shell for local ASR evidence." >&2
    exit 77
  fi

  if [[ -n "${CODEX_SANDBOX:-}" ]] &&
    grep -q '/usr/bin/say produced no audio samples' <<<"$smoke_output"; then
    echo "Local transcription smoke skipped: /usr/bin/say produced no audio samples inside CODEX_SANDBOX=$CODEX_SANDBOX; rerun in a normal desktop shell for local ASR evidence." >&2
    exit 77
  fi

  exit "$smoke_status"
}

printf "%s\n" "$smoke_output"
