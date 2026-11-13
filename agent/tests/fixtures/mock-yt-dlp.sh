#!/usr/bin/env bash
# Test-only stand-in for yt-dlp, used by agent/tests/source-integrity-test.ps1 through a
# test vault's config/vault.json yt_dlp_path. Never used by production code paths.
#   Channel scan (--flat-playlist): prints the lines of $WIKIAGENT_TEST_YTDLP_CHANNEL
#   (one "id|title" per line).
#   Caption download: writes <dir>/<id>.en-orig.vtt (dir taken from the -o template)
#   holding a one-cue caption naming the video_id, unless the id is listed in
#   $WIKIAGENT_TEST_YTDLP_FAIL_IDS (comma-separated), which exits 1.
#   Every call is appended to $WIKIAGENT_TEST_YTDLP_LOG if set.
[ -n "$WIKIAGENT_TEST_YTDLP_LOG" ] && echo "$*" >> "$WIKIAGENT_TEST_YTDLP_LOG"
for a in "$@"; do
  if [ "$a" = "--flat-playlist" ]; then
    [ -n "$WIKIAGENT_TEST_YTDLP_CHANNEL" ] && cat "$WIKIAGENT_TEST_YTDLP_CHANNEL"
    exit 0
  fi
done
out=""; url=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in https://www.youtube.com/watch?v=*) url="$a";; esac
  prev="$a"
done
id="${url#https://www.youtube.com/watch?v=}"
case ",$WIKIAGENT_TEST_YTDLP_FAIL_IDS," in *",$id,"*) echo "ERROR: mock failure for $id"; exit 1;; esac
dir="$(dirname "$out")"
mkdir -p "$dir"
printf 'WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nTranscript of video %s\n' "$id" > "$dir/$id.en-orig.vtt"
exit 0
