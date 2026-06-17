#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHRASE="${MY_OWN_VOICE_WHISPERKIT_BENCHMARK_PHRASE:-my own voice quick dictation benchmark with punctuation numbers dates and enough words to measure local transcription speed}"
MAX_SECONDS="${MY_OWN_VOICE_WHISPERKIT_BENCHMARK_MAX_SECONDS:-30}"
MODELS_CSV="${MY_OWN_VOICE_WHISPERKIT_BENCHMARK_MODELS:-large-v3-v20240930_626MB,large-v3-v20240930_turbo_632MB}"
TIMEOUT_SECONDS="${MY_OWN_VOICE_WHISPERKIT_BENCHMARK_TIMEOUT_SECONDS:-600}"

if [[ ! -x /usr/bin/say ]]; then
  echo "WhisperKit benchmark skipped: /usr/bin/say is unavailable." >&2
  exit 77
fi

cd "$ROOT_DIR"
source "$ROOT_DIR/script/swiftpm_env.sh"

IFS=',' read -r -a models <<<"$MODELS_CSV"
failures=0

run_with_timeout() {
  local output_file
  local pid
  local started_at
  local now
  local status

  output_file="$(mktemp "${TMPDIR:-/tmp}/my-own-voice-whisperkit-benchmark.XXXXXX")"
  "$@" >"$output_file" 2>&1 &
  pid=$!
  started_at="$(date +%s)"

  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    if (( now - started_at > TIMEOUT_SECONDS )); then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$output_file"
      rm -f "$output_file"
      echo "WhisperKit benchmark timed out after ${TIMEOUT_SECONDS}s." >&2
      return 124
    fi
    sleep 1
  done

  wait "$pid"
  status=$?
  cat "$output_file"
  rm -f "$output_file"
  return "$status"
}

for model in "${models[@]}"; do
  [[ -n "$model" ]] || continue
  echo "==> Benchmarking WhisperKit $model"
  run_with_timeout swift run "${SWIFTPM_COMMON_ARGS[@]}" LocalTranscriptionSmoke \
    --engine whisperkit \
    --whisperkit-model "$model" \
    --phrase "$PHRASE" \
    --max-seconds "$MAX_SECONDS" || failures=1
done

exit "$failures"
