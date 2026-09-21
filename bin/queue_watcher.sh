#!/bin/bash
# queue_watcher.sh - works through every audio file waiting in the inbox,
# oldest first, one at a time, and keeps re-checking the inbox after each
# batch until it's genuinely empty (so a file that arrives while another
# is still being processed gets picked up right away, not on the next
# launchd trigger).
#
# This is launched automatically by launchd whenever a file is added to
# ~/Stenographer/inbox, and again every couple of minutes regardless as a
# safety net (see com.stenographer.watcher.plist). You can also run it by
# hand at any time -- it's safe to do so even if a launchd-triggered run
# is already going, it will just exit immediately instead of doubling up.
#
# Why strictly one at a time: this pipeline runs a 3B-parameter language
# model on a machine with limited RAM and only two CPU cores. Running two
# copies at once would fight over both, and likely make BOTH slower rather
# than getting more done. So: one file fully finishes before the next one
# starts, however many are queued up.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$STENO_INBOX" "$STENO_PROCESSING" "$STENO_ARCHIVE" "$STENO_FAILED" "$STENO_NOTES" "$STENO_LOGS"

LOCKDIR="$STENO_HOME/.watcher.lock"
LOGFILE="$STENO_LOGS/watcher_$(date +%Y%m%d).log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" | tee -a "$LOGFILE"
}

# --- Locking -----------------------------------------------------------
# mkdir is atomic on a local filesystem: two processes can't both succeed
# at creating the same directory, so this can't double-run even if launchd
# fires twice in quick succession. If a previous run crashed and left a
# stale lock behind, we notice its PID is dead and reclaim it.
acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ > "$LOCKDIR/pid"
    return 0
  fi
  local pid
  pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1 # a real run is in progress
  fi
  # stale lock from a crashed/killed run -- reclaim it
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null && echo $$ > "$LOCKDIR/pid" && return 0
  return 1
}
release_lock() { rm -rf "$LOCKDIR"; }

if ! acquire_lock; then
  log "Another watcher run is already in progress -- exiting. It will pick up any newly-added files itself."
  exit 0
fi
trap release_lock EXIT

# --- Helpers -------------------------------------------------------------

# A file that's still being copied/downloaded into the inbox will keep
# growing. Wait a couple of seconds and compare sizes before claiming it,
# so we don't try to transcribe a half-written file.
is_stable() {
  local f="$1" size1 size2
  size1="$(stat -f '%z' "$f" 2>/dev/null)" || return 1
  sleep 2
  size2="$(stat -f '%z' "$f" 2>/dev/null)" || return 1
  [ "$size1" = "$size2" ]
}

# Lists files in the inbox oldest-first (by modification time), using
# NUL-separated output throughout so filenames with spaces are handled
# correctly. Uses macOS's BSD `stat` (-f '%m %N'), not the GNU syntax.
queued_files() {
  find "$STENO_INBOX" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null \
    | xargs -0 stat -f '%m %N' 2>/dev/null \
    | sort -n \
    | cut -d' ' -f2-
}

# --- Main loop -------------------------------------------------------------

log "Watcher started (PID $$)."
processed_any=0

# Outer loop: keep sweeping the inbox until a full pass finds nothing new
# to claim. This is what makes it a real queue -- finishing one file
# immediately checks for the next, rather than waiting for another
# launchd trigger.
while :; do
  found_this_pass=0

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue

    if ! is_stable "$file"; then
      log "Skipping $(basename "$file") -- still being copied, will pick it up next run."
      continue
    fi

    claimed="$STENO_PROCESSING/$(basename "$file")"
    if ! mv "$file" "$claimed" 2>/dev/null; then
      log "Could not claim $(basename "$file") (already moved by another run?), skipping."
      continue
    fi

    processed_any=1
    found_this_pass=1
    log "Processing $(basename "$claimed")..."
    if "$SCRIPT_DIR/dictate.sh" "$claimed" >>"$LOGFILE" 2>&1; then
      mv "$claimed" "$STENO_ARCHIVE/" 2>/dev/null
      log "Done: $(basename "$claimed") -> archived, note written to $STENO_NOTES"
    else
      mv "$claimed" "$STENO_FAILED/" 2>/dev/null
      log "FAILED: $(basename "$claimed") -> moved to failed/. See $LOGFILE for details."
    fi
  done < <(queued_files)

  [ "$found_this_pass" -eq 1 ] || break
done

if [ "$processed_any" -eq 0 ]; then
  log "No files waiting."
fi

log "Watcher finished."
