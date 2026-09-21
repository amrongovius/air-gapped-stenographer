#!/bin/bash
# config.sh - central configuration for the Air-Gapped Digital Stenographer
#
# install.command overwrites this file with the exact paths it used on your
# Mac, so you normally never need to touch it. It's shown here with sane
# defaults in case you're running the scripts by hand before installing.

# Background jobs launched by launchd (like the automatic queue watcher) get
# a much smaller PATH than your interactive Terminal, so tools installed to
# /usr/local/bin (Intel Macs) or /opt/homebrew/bin (Apple Silicon Macs) --
# like ffmpeg -- would otherwise be invisible to them.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

STENO_HOME="${STENO_HOME:-$HOME/Stenographer}"
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper.cpp}"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"

WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
WHISPER_MODEL="$WHISPER_DIR/models/ggml-base.en.bin"

LLAMA_BIN="$LLAMA_DIR/build/bin/llama-cli"
LLAMA_MODEL="$LLAMA_DIR/llama-3.2-3b.gguf"

# How much context (in tokens) llama.cpp is allowed to use. This has to be
# big enough to hold the ENTIRE transcript plus the note it writes back out,
# or the model silently loses the earlier part of long recordings.
# 16384 is an estimate good for roughly a 60-75 minute recording at normal
# speaking pace -- see README.md "Known limits" before trusting it on
# anything you can't afford to lose. Raise it if you need longer recordings
# and have RAM to spare; lower it if the machine swaps or runs out of memory.
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"

STENO_INBOX="$STENO_HOME/inbox"
STENO_PROCESSING="$STENO_HOME/processing"
STENO_ARCHIVE="$STENO_HOME/archive"
STENO_FAILED="$STENO_HOME/failed"
STENO_NOTES="$STENO_HOME/notes"
STENO_LOGS="$STENO_HOME/logs"
STENO_PROMPTS="$STENO_HOME/prompts"
DEFAULT_PROMPT="$STENO_PROMPTS/general.txt"

LLAMA_SERVER_BIN="$LLAMA_DIR/build/bin/llama-server"
LLAMA_SERVER_PORT="${LLAMA_SERVER_PORT:-8080}"
LLAMA_SERVER_URL="http://127.0.0.1:$LLAMA_SERVER_PORT"
