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
# Hard cap (seconds) on EACH cookie-based yt-dlp call. --cookies-from-browser can hang
# indefinitely on a macOS Keychain access prompt; this bounds it so the loop moves on.
COOKIE_TIMEOUT="${COOKIE_TIMEOUT:-${DOUYIN_COOKIE_TIMEOUT:-30}}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

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
# Bounded yt-dlp: ytdlp <secs|0> <args...>. secs>0 enforces a hard timeout (kills the
# process -- and dismisses a hung Keychain prompt -- if it exceeds the limit). Uses
# timeout/gtimeout when present, else a background-watchdog fallback (macOS ships no `timeout`).
ytdlp() {
  local secs="$1"; shift
  if [ "$secs" -le 0 ]; then yt-dlp "$@"; return $?; fi
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" -k 5 "$secs" yt-dlp "$@"; return $?; fi
  local p w rc=0
  yt-dlp "$@" & p=$!
  ( sleep "$secs"; kill -TERM "$p" 2>/dev/null; sleep 3; kill -KILL "$p" 2>/dev/null ) & w=$!
  wait "$p" 2>/dev/null || rc=$?
  kill -TERM "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  return "$rc"
}
# fetch <secs|0> [extra yt-dlp args...] -- secs bounds each underlying yt-dlp call.
fetch() {
  local secs="$1"; shift
  ytdlp "$secs" --no-warnings --skip-download --write-info-json -o "v.%(ext)s" "$@" "$URL" >/dev/null 2>&1 || true
  ytdlp "$secs" --no-warnings -f "ba/b" -x --audio-format wav \
    --postprocessor-args "-ar 16000 -ac 1" -o "audio.%(ext)s" "$@" "$URL" >/dev/null 2>&1 || true
}
fetch 0   # plain attempt: no cookies, no Keychain risk, so no timeout
if [ ! -f "$WORKDIR/audio.wav" ]; then
  for b in $COOKIE_BROWSERS; do
    fetch "$COOKIE_TIMEOUT" --cookies-from-browser "$b"
    [ -f "$WORKDIR/audio.wav" ] && break
  done
fi

# --- Douyin last resort: parse-API fallback (yt-dlp can't beat a_bogus risk-control) ---
# Douyin's detail endpoint returns an empty body unless the request ran their in-browser
# a_bogus JS challenge, so yt-dlp (even nightly, with cookies + TLS impersonation) gets no
# video URL. The helper walks a chain of free parse APIs that run the challenge server-side,
# downloads from Douyin's CDN, and writes audio.wav + meta.json here. Douyin-only on purpose:
# IG/FB/XHS failures are login-gating that cookies, not parsers, fix.
if [ ! -f "$WORKDIR/audio.wav" ] && [ "$PLATFORM" = "douyin" ]; then
  python3 "$HERE/douyin-parse-fallback.py" "$URL" "$WORKDIR" >&2 || true
fi
[ -f "$WORKDIR/audio.wav" ] || { echo "DOWNLOAD_FAILED url=$URL platform=$PLATFORM (blocked: Douyin a_bogus risk-control AND all parse APIs missed, or Instagram/Facebook login-gating. For IG/FB open the video once in your logged-in browser then retry, or set COOKIE_BROWSER=<that-browser>; keep yt-dlp recent. Don't fake a transcript.)"; exit 5; }

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
# Prefer a meta.json already written by the parse-API fallback (yt-dlp produced no
# v.info.json on that path); only build from yt-dlp's info when none exists.
meta_path = os.path.join(wd, 'meta.json')
meta = {}
if os.path.exists(meta_path):
    try:
        meta = json.load(open(meta_path, encoding='utf-8'))
    except Exception:
        meta = {}
if not meta:
    meta = {k: info.get(k) for k in keys}
meta.setdefault('platform', platform)
open(meta_path, 'w', encoding='utf-8').write(
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
