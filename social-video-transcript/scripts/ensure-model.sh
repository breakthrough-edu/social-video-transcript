#!/usr/bin/env bash
# social-video-transcript :: ensure a local WhisperKit large-v3 CoreML model exists.
#
# Scans the common model locations first; only downloads when explicitly asked
# (--download), because the model is ~1.5 GB. Downloads the EXACT snapshot the skill
# is tuned on (openai_whisper-large-v3-v20240930) from Hugging Face. NOTE: whisperkit-cli
# has no standalone download command -- the model is fetched as a side effect of
# `transcribe`, which REQUIRES an audio path, so we feed it a 1s silent WAV (built with
# ffmpeg). The model lands nested under <dir>/models/argmaxinc/whisperkit-coreml/<name>.
#
# Usage:
#   ensure-model.sh                  # scan only      -> MODEL_PATH=<dir> | MODEL_NOT_FOUND
#   ensure-model.sh --download       # scan; if absent, download to default dir, print MODEL_PATH
#   ensure-model.sh --download <dir> # download target override
#
# Env overrides:
#   WHISPER_MODEL_PATH  explicit single-model dir to prefer
#   WHISPER_MODELS_DIR  where to keep / download models (default ~/.cache/whisperkit-models)
#   WHISPER_MODEL_NAME  model snapshot to want/download (default large-v3-v20240930)
#
# Output markers: MODEL_PATH=<dir> | MODEL_NOT_FOUND | MISSING_TOOL=<t> | DOWNLOAD_FAILED ...
set -euo pipefail

WANT="${WHISPER_MODEL_NAME:-large-v3-v20240930}"   # the exact model the skill is tuned on
PREFIX="openai_whisper"
WANT_EXACT="$PREFIX-$WANT"
DL_DIR="${2:-${WHISPER_MODELS_DIR:-$HOME/.cache/whisperkit-models}}"

# Candidate roots to scan for an already-present model (generic + common skill caches).
ROOTS=(
  "${WHISPER_MODEL_PATH:-}"
  "${WHISPER_MODELS_DIR:-}"
  "$HOME/.cache/whisperkit-models"
  "$HOME/.config/meeting-transcripts/models"
  "$HOME/Documents/Code/whisper-models"
)

# Print the best matching model dir (one holding AudioEncoder.mlmodelc), preferring
# the exact wanted snapshot, then any large-v3 variant. Empty + non-zero if none.
find_model() {
  local exact="" any="" enc d base
  for root in "${ROOTS[@]}"; do
    [ -n "$root" ] && [ -e "$root" ] || continue
    # root may itself be a model dir
    if [ -d "$root/AudioEncoder.mlmodelc" ]; then
      base="$(basename "$root")"
      [ "$base" = "$WANT_EXACT" ] && exact="$root"
      case "$base" in *large-v3*) [ -z "$any" ] && any="$root";; esac
    fi
    # otherwise search a few levels down
    while IFS= read -r enc; do
      d="$(dirname "$enc")"; base="$(basename "$d")"
      [ "$base" = "$WANT_EXACT" ] && exact="$d"
      case "$base" in *large-v3*) [ -z "$any" ] && any="$d";; esac
    done < <(find "$root" -maxdepth 7 -type d -name AudioEncoder.mlmodelc 2>/dev/null | grep -v '/\.cache/')
  done
  if [ -n "$exact" ]; then printf '%s' "$exact"; return 0; fi
  if [ -n "$any" ];   then printf '%s' "$any";   return 0; fi
  return 1
}

FOUND="$(find_model || true)"
if [ -n "$FOUND" ]; then
  echo "MODEL_PATH=$FOUND"
  exit 0
fi

if [ "${1:-}" != "--download" ]; then
  echo "MODEL_NOT_FOUND"
  exit 0
fi

# --- download (only on explicit --download) ---
command -v whisperkit-cli >/dev/null 2>&1 || { echo "MISSING_TOOL=whisperkit-cli"; exit 3; }
command -v ffmpeg >/dev/null 2>&1 || { echo "MISSING_TOOL=ffmpeg"; exit 3; }
mkdir -p "$DL_DIR"
LOG="$DL_DIR/.download.log"
: >"$LOG"
# whisperkit-cli has no standalone "download" command: the model is fetched as a side
# effect of `transcribe` when --model is given without --model-path. transcribe REQUIRES
# an audio path, so feed it a 1s silent WAV; the model lands under --download-model-path.
# We ignore whisperkit's exit code (transcribing silence may warn) and verify by file.
SILENCE="$DL_DIR/.silence.wav"
ffmpeg -y -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -ar 16000 -ac 1 "$SILENCE" >>"$LOG" 2>&1 || true
whisperkit-cli transcribe --audio-path "$SILENCE" --model "$WANT" \
  --download-model-path "$DL_DIR" >>"$LOG" 2>&1 || true
rm -f "$SILENCE"

# Locate what landed (ignore the HF .cache/ staging copies): prefer the exact snapshot,
# else any large-v3 bundle.
RESULT="$(find "$DL_DIR" -maxdepth 7 -type d -name AudioEncoder.mlmodelc 2>/dev/null \
  | grep -v '/\.cache/' | sed 's#/AudioEncoder.mlmodelc$##' | grep -F "$WANT_EXACT" | head -1 || true)"
[ -z "$RESULT" ] && RESULT="$(find "$DL_DIR" -maxdepth 7 -type d -name AudioEncoder.mlmodelc 2>/dev/null \
  | grep -v '/\.cache/' | sed 's#/AudioEncoder.mlmodelc$##' | grep large-v3 | head -1 || true)"

if [ -n "$RESULT" ] && [ -d "$RESULT/AudioEncoder.mlmodelc" ]; then
  echo "MODEL_PATH=$RESULT"
  exit 0
fi
echo "DOWNLOAD_FAILED dir=$DL_DIR (see $LOG)"
exit 5
