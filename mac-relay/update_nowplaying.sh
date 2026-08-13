#!/bin/bash
# Reads macOS's system-wide Now Playing info (populated by Spotify Web
# Player via the standard Media Session API, or anything else playing)
# and relays it to a private GitHub gist that the iOS app polls.
# Only writes when the track/artist actually changes, to avoid spamming
# the gist's revision history and GitHub's API.
#
# Runs as one long-lived loop (launchd KeepAlive, not StartInterval) —
# StartInterval only guarantees "at least every N seconds" and macOS is
# known to coalesce/delay those firings to save power, which was the real
# cause of new songs feeling slow to pick up. A self-contained sleep loop
# gives much tighter, more predictable timing.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

GIST_ID="${NOW_PLAYING_GIST_ID:?Set NOW_PLAYING_GIST_ID before running update_nowplaying.sh}"
GITHUB_TOKEN="${GITHUB_TOKEN:?Set GITHUB_TOKEN before running update_nowplaying.sh}"
STATE_FILE="/tmp/lyrics_nowplaying_state.txt"
LOG_FILE="/tmp/lyrics_nowplaying_timing.log"
LOOP_INTERVAL="0.25"
NEW_TRACK_ZERO_ELAPSED_BIAS="3"
# 5s / 0.25s loop interval. A momentary blip (title briefly missing, or the
# key genuinely still there but stale for one poll) shouldn't flash "Paused"
# on CarPlay -- only a pause sustained this long counts.
PAUSE_CONFIRM_TICKS=20
PAUSE_STREAK=0

is_zeroish_elapsed() {
  python3 -c '
import sys
try:
    value = float(sys.argv[1])
except (IndexError, ValueError):
    value = 0.0
sys.exit(0 if value <= 0.05 else 1)
' "$1"
}

while true; do
  TITLE=$(nowplaying-cli get title 2>/dev/null || echo "")
  ARTIST=$(nowplaying-cli get artist 2>/dev/null || echo "")
  RATE=$(nowplaying-cli get playbackRate 2>/dev/null || echo "0")
  ELAPSED=$(nowplaying-cli get elapsedTime 2>/dev/null || echo "0")
  DURATION=$(nowplaying-cli get duration 2>/dev/null || echo "0")

  # A paused Spotify Connect session omits PlaybackRate from the info dict
  # entirely rather than reporting 0, which nowplaying-cli renders as the
  # literal string "null" -- so that has to be checked for explicitly, not
  # just "0".
  if [ "$RATE" = "0" ] || [ "$RATE" = "null" ] || [ -z "$TITLE" ] || [ -z "$ARTIST" ]; then
    LOOKS_PAUSED=1
  else
    LOOKS_PAUSED=0
  fi

  if [ "$LOOKS_PAUSED" = "1" ]; then
    PAUSE_STREAK=$((PAUSE_STREAK + 1))
  else
    PAUSE_STREAK=0
  fi

  # Not yet confirmed paused -- ignore the blip and leave the gist as-is
  # rather than reporting "nothing playing" prematurely.
  if [ "$LOOKS_PAUSED" = "1" ] && [ "$PAUSE_STREAK" -lt "$PAUSE_CONFIRM_TICKS" ]; then
    sleep "$LOOP_INTERVAL"
    continue
  fi

  if [ "$LOOKS_PAUSED" = "1" ]; then
    TITLE=""
    ARTIST=""
    ELAPSED="0"
  fi

  CURRENT_STATE="$TITLE|$ARTIST"
  LAST_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")

  if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
    if [ "$LOOKS_PAUSED" = "0" ] && is_zeroish_elapsed "$ELAPSED"; then
      ELAPSED="$NEW_TRACK_ZERO_ELAPSED_BIAS"
      printf '[LyricsTiming] %s relay_elapsed_biased bias_seconds="%s" track="%s" artist="%s"\n' \
        "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$NEW_TRACK_ZERO_ELAPSED_BIAS" "$TITLE" "$ARTIST" >> "$LOG_FILE"
    fi

    echo "$CURRENT_STATE" > "$STATE_FILE"

    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    WRITE_STARTED_MS=$(python3 -c 'import time; print(int(time.time() * 1000))')
    printf '[LyricsTiming] %s relay_state_changed track="%s" artist="%s" elapsed="%s" duration="%s"\n' \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$TITLE" "$ARTIST" "$ELAPSED" "$DURATION" >> "$LOG_FILE"

    PAYLOAD=$(TITLE="$TITLE" ARTIST="$ARTIST" TIMESTAMP="$TIMESTAMP" ELAPSED="$ELAPSED" DURATION="$DURATION" python3 -c '
import json, os

def to_float(s, default=0.0):
    try:
        return float(s)
    except ValueError:
        return default

inner = json.dumps({
    "track": os.environ["TITLE"],
    "artist": os.environ["ARTIST"],
    "elapsedSeconds": to_float(os.environ["ELAPSED"]),
    "updatedAt": os.environ["TIMESTAMP"],
    "duration": to_float(os.environ["DURATION"]),
})
payload = {"files": {"nowplaying.json": {"content": inner}}}
print(json.dumps(payload))
')

    HTTP_STATUS=$(curl -s -o /tmp/lyrics_nowplaying_last_response.json -w "%{http_code}" -X PATCH "https://api.github.com/gists/$GIST_ID" \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -d "$PAYLOAD")
    WRITE_FINISHED_MS=$(python3 -c 'import time; print(int(time.time() * 1000))')
    WRITE_MS=$((WRITE_FINISHED_MS - WRITE_STARTED_MS))
    printf '[LyricsTiming] %s relay_gist_patch_done status="%s" write_ms="%s" track="%s" artist="%s"\n' \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$HTTP_STATUS" "$WRITE_MS" "$TITLE" "$ARTIST" >> "$LOG_FILE"
  fi

  sleep "$LOOP_INTERVAL"
done
