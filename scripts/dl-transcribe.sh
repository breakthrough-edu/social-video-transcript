#!/usr/bin/env bash
# social-video-transcript :: resolve + download + extract audio + local Whisper transcribe.
# Works with any platform yt-dlp supports -- Douyin, Xiaohongshu (小红书), Instagram,
# Facebook, TikTok, and more. Prints WORKDIR + PLATFORM + metadata + RAW transcript to
# stdout. Leaves files in a /tmp mktemp WORKDIR for the agent to read; the agent removes
# WORKDIR after writing the output .md.
#
# Usage:  dl-transcribe.sh "<video url or full share text from any supported platform>"
# Output markers:  WORKDIR= / PLATFORM= / ----META---- / ----RAW---- / ----END----
# Error markers:   MISSING_TOOL= / MISSING_MODEL= / NO_URL / DOWNLOAD_FAILED / TRANSCRIBE_FAILED
# On any failure after the temp dir is made, WORKDIR= is still printed (EXIT trap) so the
# agent can clean up and inspect logs.
set -euo pipefail

RAW_INPUT="${1:?usage: dl-transcribe.sh <video-url-or-share-text>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${WHISPER_MODEL_PATH:-$HOME/.cache/whisperkit-models/openai_whisper-large-v3-v20240930}"
# Language: by default let Whisper AUTO-DETECT (no --language flag). Force one only if the
# user explicitly sets WHISPER_LANG (e.g. WHISPER_LANG=zh for a noisy Chinese clip).
WLANG="${WHISPER_LANG:-}"
# Browsers to try for cookies if the first download is blocked (risk-control on Douyin,
# login-gating on Instagram/Facebook). Override with one browser, e.g. COOKIE_BROWSER=safari.
COOKIE_BROWSERS="${COOKIE_BROWSER:-${DOUYIN_COOKIE_BROWSER:-chrome safari firefox edge arc brave}}"

# --- pre-flight ---
for t in yt-dlp ffmpeg whisperkit-cli python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "MISSING_TOOL=$t"; exit 3; }
done

# --- resolve model: honor WHISPER_MODEL_PATH / default, else scan via ensure-model.sh ---
# (so a model found at a non-default location is used even without a manual export.)
if [ ! -d "$MODEL" ] && [ -x "$HERE/ensure-model.sh" ]; then
  RESOLVED="$("$HERE/ensure-model.sh" 2>/dev/null | sed -n 's/^MODEL_PATH=//p' | head -1)" || RESOLVED=""
  [ -n "$RESOLVED" ] && MODEL="$RESOLVED"
fi
[ -d "$MODEL" ] || { echo "MISSING_MODEL=$MODEL"; exit 4; }

# --- resolve URL out of pasted share text (short link, full video URL, or share blob) ---
# Prefer a known-platform host if present; else fall back to the first URL in the text.
KNOWN='douyin\.com|iesdouyin\.com|xiaohongshu\.com|xhslink\.com|instagram\.com|facebook\.com|fb\.watch|fb\.com|tiktok\.com'
URL=$(printf '%s' "$RAW_INPUT" | grep -oE "https?://[a-zA-Z0-9./_?=&%~-]*($KNOWN)[a-zA-Z0-9./_?=&%~-]*" | head -1 || true)
[ -z "$URL" ] && URL=$(printf '%s' "$RAW_INPUT" | grep -oE 'https?://[a-zA-Z0-9./_?=&%~-]+' | head -1 || true)
[ -z "$URL" ] && { echo "NO_URL"; exit 2; }

# --- classify platform from the URL host (for filename + metadata labelling) ---
case "$URL" in
  *douyin.com*|*iesdouyin.com*)      PLATFORM=douyin ;;
  *xiaohongshu.com*|*xhslink.com*)   PLATFORM=xiaohongshu ;;
  *instagram.com*)                   PLATFORM=instagram ;;
  *facebook.com*|*fb.watch*|*fb.com*) PLATFORM=facebook ;;
  *tiktok.com*)                      PLATFORM=tiktok ;;
  *)                                 PLATFORM=video ;;
esac

WORKDIR=$(mktemp -d /tmp/social-video-transcript.XXXXXX)
# Always surface WORKDIR on an unexpected/early-failure exit so nothing is orphaned silently.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "WORKDIR=$WORKDIR"; fi' EXIT
cd "$WORKDIR"

# --- download metadata + 16kHz mono WAV; retry over browsers if the first try is blocked ---
fetch() {
  yt-dlp --no-warnings --skip-download --write-info-json -o "v.%(ext)s" "$@" "$URL" >/dev/null 2>&1 || true
  yt-dlp --no-warnings -f "ba/b" -x --audio-format wav \
    --postprocessor-args "-ar 16000 -ac 1" -o "audio.%(ext)s" "$@" "$URL" >/dev/null 2>&1 || true
}
fetch
if [ ! -f "$WORKDIR/audio.wav" ]; then
  for b in $COOKIE_BROWSERS; do
    fetch --cookies-from-browser "$b"
    [ -f "$WORKDIR/audio.wav" ] && break
  done
fi
[ -f "$WORKDIR/audio.wav" ] || { echo "DOWNLOAD_FAILED url=$URL platform=$PLATFORM (blocked: Douyin risk-control, or Instagram/Facebook login-gating. Open the video once in your logged-in browser then retry, set COOKIE_BROWSER=<that-browser>, update yt-dlp, or use a parse-API fallback)"; exit 5; }

# --- transcribe (local large-v3; --model-path => fully offline, no HF download/hang) ---
# Auto-detect language unless WHISPER_LANG was set.
mkdir -p report
LANG_ARGS=()
[ -n "$WLANG" ] && LANG_ARGS=(--language "$WLANG")
if ! whisperkit-cli transcribe \
      --audio-path "$WORKDIR/audio.wav" \
      --model-path "$MODEL" \
      ${LANG_ARGS[@]+"${LANG_ARGS[@]}"} \
      --report --report-path "$WORKDIR/report" >"$WORKDIR/whisper.log" 2>&1; then
  echo "TRANSCRIBE_FAILED (whisperkit-cli error; see $WORKDIR/whisper.log)"
  exit 6
fi

# --- strip Whisper special tokens from SRT -> raw.txt; collect metadata -> meta.json ---
# Metadata is best-effort: a missing/garbage v.info.json must NEVER discard a good transcript.
python3 - "$WORKDIR" "$PLATFORM" <<'PY'
import json, re, sys, os
wd = sys.argv[1]
platform = sys.argv[2]
info = {}
p = os.path.join(wd, 'v.info.json')
if os.path.exists(p):
    try:
        info = json.load(open(p, encoding='utf-8'))
    except Exception:
        info = {}
body = ''
srt_path = os.path.join(wd, 'report', 'audio.srt')
if os.path.exists(srt_path):
    srt = open(srt_path, encoding='utf-8').read()
    cues = re.findall(r'\d+\n[\d:,]+ --> [\d:,]+\n(.*?)(?:\n\n|\Z)', srt, re.S)
    body = ''.join(re.sub(r'<\|[^|]*\|>', '', c).strip() for c in cues if c.strip())
open(os.path.join(wd, 'raw.txt'), 'w', encoding='utf-8').write(body)
keys = ['title','description','uploader','uploader_id','duration','webpage_url',
        'upload_date','like_count','comment_count','repost_count','track']
meta = {k: info.get(k) for k in keys}
meta['platform'] = platform
open(os.path.join(wd, 'meta.json'), 'w', encoding='utf-8').write(
    json.dumps(meta, ensure_ascii=False, indent=2))
PY

# Transcription "succeeded" but produced no text (e.g. no speech / music-only clip).
if [ ! -s "$WORKDIR/raw.txt" ]; then
  echo "TRANSCRIBE_FAILED (empty transcript -- no speech detected? see $WORKDIR/whisper.log)"
  exit 6
fi

trap - EXIT   # success: clear the trap so WORKDIR is printed exactly once below
echo "WORKDIR=$WORKDIR"
echo "PLATFORM=$PLATFORM"
echo "----META----"
cat "$WORKDIR/meta.json"
echo ""
echo "----RAW----"
cat "$WORKDIR/raw.txt"
echo ""
echo "----END----"
