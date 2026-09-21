#!/bin/bash
# dictate.sh - transcribe one audio file and structure it into a Markdown note.
#
# Talks to llama-server (llama.cpp's background API mode) rather than the
# interactive llama-cli chat interface, because newer llama.cpp builds
# render a full chat display straight to the terminal for any chat-capable
# model -- which can't be captured into a file. llama-server just answers
# requests with no display at all, so it's the reliable way to script this.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

if [ $# -lt 1 ]; then
  fail "Usage: dictate.sh /path/to/audiofile [--prompt name] [--outdir path]"
fi

AUDIO_FILE="$1"
shift

PROMPT_FILE="$DEFAULT_PROMPT"
OUT_DIR="$STENO_NOTES"

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt)
      [ $# -ge 2 ] || fail "--prompt needs a template name (e.g. --prompt meeting)"
      PROMPT_FILE="$STENO_PROMPTS/$2.txt"
      shift 2
      ;;
    --outdir)
      [ $# -ge 2 ] || fail "--outdir needs a path"
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[ -f "$AUDIO_FILE" ]       || fail "Audio file not found: $AUDIO_FILE"
[ -x "$WHISPER_BIN" ]      || fail "whisper-cli not found at $WHISPER_BIN (check WHISPER_DIR in config.sh)"
[ -f "$WHISPER_MODEL" ]    || fail "Whisper model not found at $WHISPER_MODEL"
[ -x "$LLAMA_SERVER_BIN" ] || fail "llama-server not found at $LLAMA_SERVER_BIN (check LLAMA_DIR in config.sh)"
[ -f "$LLAMA_MODEL" ]      || fail "Llama model not found at $LLAMA_MODEL"
[ -f "$PROMPT_FILE" ]      || fail "Prompt template not found: $PROMPT_FILE"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

mkdir -p "$OUT_DIR" || fail "Could not create output directory: $OUT_DIR"
mkdir -p "$STENO_LOGS"

BASENAME="$(basename "${AUDIO_FILE%.*}")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/steno.XXXXXX")" || fail "Could not create a temp working directory"
trap 'rm -rf "$WORKDIR"' EXIT

WAV_FILE="$WORKDIR/input.wav"
TRANSCRIPT_BASE="$WORKDIR/transcript"
TRANSCRIPT_TXT="$TRANSCRIPT_BASE.txt"
OUTPUT_NOTE="$OUT_DIR/${BASENAME}_${TIMESTAMP}.md"

echo "[1/3] Preparing audio: $(basename "$AUDIO_FILE")"
EXT="${AUDIO_FILE##*.}"
EXT_LOWER="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"
if [ "$EXT_LOWER" = "wav" ]; then
  cp "$AUDIO_FILE" "$WAV_FILE" || fail "Could not copy $AUDIO_FILE"
else
  command -v ffmpeg >/dev/null 2>&1 \
    || fail "ffmpeg is required to read .$EXT files. Install it with: brew install ffmpeg"
  ffmpeg -y -loglevel error -i "$AUDIO_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV_FILE" \
    || fail "ffmpeg could not convert $AUDIO_FILE to 16kHz mono WAV"
fi

echo "[2/3] Transcribing with whisper.cpp..."
"$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$WAV_FILE" -nt -otxt -of "$TRANSCRIPT_BASE" \
  || fail "whisper-cli failed while transcribing $AUDIO_FILE"
[ -s "$TRANSCRIPT_TXT" ] \
  || fail "Transcription produced an empty file -- check the audio isn't silent, too quiet, or corrupt"

server_is_up() {
  curl -s -o /dev/null --max-time 2 "$LLAMA_SERVER_URL/health"
}

if ! server_is_up; then
  echo "Starting llama-server (first run loads the model, roughly 10-15 seconds)..."
  nohup "$LLAMA_SERVER_BIN" -m "$LLAMA_MODEL" -c "$LLAMA_CTX_SIZE" --host 127.0.0.1 --port "$LLAMA_SERVER_PORT" \
    > "$STENO_LOGS/llama-server.log" 2>&1 &
  disown

  waited=0
  until server_is_up; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 60 ]; then
      fail "llama-server did not come up within 60 seconds -- check $STENO_LOGS/llama-server.log"
    fi
  done
fi

echo "[3/3] Structuring note with llama-server (context size: $LLAMA_CTX_SIZE tokens)..."

REQUEST_JSON="$WORKDIR/request.json"
RESPONSE_JSON="$WORKDIR/response.json"

if command -v jq >/dev/null 2>&1; then
  jq -n --rawfile sys "$PROMPT_FILE" --rawfile usr "$TRANSCRIPT_TXT" \
    '{messages: [{role: "system", content: $sys}, {role: "user", content: $usr}]}' \
    > "$REQUEST_JSON" || fail "Could not build the request (jq)"
else
  python3 -c "
import json, sys
sys_txt = open(sys.argv[1]).read()
usr_txt = open(sys.argv[2]).read()
print(json.dumps({'messages': [{'role': 'system', 'content': sys_txt}, {'role': 'user', 'content': usr_txt}]}))
" "$PROMPT_FILE" "$TRANSCRIPT_TXT" > "$REQUEST_JSON" || fail "Could not build the request (python3)"
fi

curl -s --max-time 600 "$LLAMA_SERVER_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d @"$REQUEST_JSON" > "$RESPONSE_JSON"
[ $? -eq 0 ] || fail "Could not reach llama-server at $LLAMA_SERVER_URL"
[ -s "$RESPONSE_JSON" ] || fail "llama-server returned an empty response"

if command -v jq >/dev/null 2>&1; then
  jq -r '.choices[0].message.content // empty' "$RESPONSE_JSON" > "$OUTPUT_NOTE"
else
  python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(data['choices'][0]['message']['content'])
" "$RESPONSE_JSON" > "$OUTPUT_NOTE"
fi

if [ ! -s "$OUTPUT_NOTE" ]; then
  rm -f "$OUTPUT_NOTE"
  fail "Could not extract note text -- raw response saved at $RESPONSE_JSON"
fi
