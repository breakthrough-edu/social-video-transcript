---
name: social-video-transcript
description: Turn a short-video link from Douyin (抖音), Xiaohongshu / RED (小红书), Instagram, Facebook, or TikTok into a clean, readable markdown transcript, fully local, free, on Apple Silicon macOS. The user pastes a video link or share-text; the skill downloads the video, extracts audio, transcribes locally with Whisper large-v3 (Apple Neural Engine via whisperkit-cli, auto-detecting the language), light-cleans the raw ASR into readable prose (fixing the homophone / proper-noun errors Whisper makes, using the video's own title/topic as context), saves ONE markdown file to an output folder, deletes the downloaded media, and stops. MUST trigger when the user provides a Douyin / Xiaohongshu / 小红书 / RED / Instagram / Facebook / TikTok video link or share-text, or says "转写这个视频", "把这个视频转成文字", "transcribe this video", "transcribe this reel", "这个视频讲什么", "抖音转写", "小红书转写", "transcribe this douyin / xhs / instagram / facebook / tiktok", "social-video-transcript", or pastes a douyin.com / xiaohongshu.com / xhslink.com / instagram.com / facebook.com / fb.watch / tiktok.com link. Not for YouTube (use youtube-transcript-ingestion) or for local meeting-audio files.
---

# Social Video Transcript: 短视频链接 → 干净逐字稿

## What this skill does

Given a short-video link (or pasted share-text) from a supported platform, produce a readable transcript and save it as one markdown file:

1. Resolve the URL out of the pasted text (short links, full video URLs, or share blobs)
2. Detect the platform from the URL (douyin / xiaohongshu / instagram / facebook / tiktok / other)
3. Download metadata + extract 16kHz mono WAV (`yt-dlp` + `ffmpeg`)
4. Transcribe locally with **Whisper large-v3** via `whisperkit-cli` (Apple Neural Engine), **auto-detecting the language**
5. **Light-clean** the raw ASR into readable prose: punctuation, paragraphs, and fixing obvious homophone / proper-noun errors **using the video's own title + description as topic context** (faithful, never inventing content)
6. Save **one** markdown file to the output folder
7. **Delete the downloaded media** (the temp work dir); only the `.md` survives
8. **Stop and await the next instruction** (no auto-summary, no auto-repurpose)

Pipeline is 100% local and free (~12s for a 44s clip on Apple Silicon). Same local-Whisper lineage as `meeting-scribe`; the social-platform step is just yt-dlp on the front.

## Supported platforms

Anything `yt-dlp` can fetch works. Verified extractors: **Douyin**, **Xiaohongshu / RED (小红书)**, **Instagram** (reels + posts), **Facebook** (video + reels), **TikTok**. A link from any other yt-dlp-supported site also runs (labelled `video`).

> Download reliability differs by platform. Douyin's `a_bogus` risk-control now defeats yt-dlp outright, so the script **auto-falls-back to a parse-API chain** for Douyin links; Instagram and Facebook often require you to be **logged in** (the script auto-retries with your browser cookies). See "When the download is blocked".

## When to load

The user pastes a supported-platform link / share-text, or asks to transcribe / "讲什么" a short video. One link = one run.

## Requirements (Mac-only)

Runs on **Apple Silicon macOS**. Transcription is `whisperkit-cli` (Apple Neural Engine); the front steps use `yt-dlp` + `ffmpeg` + `python3`. Install with Homebrew:

```bash
brew install whisperkit-cli ffmpeg yt-dlp
```

Not portable to Intel mac / Windows / Linux; if you need that, use a cross-platform Whisper engine (e.g. faster-whisper / whisper.cpp) instead.

> Throughout, `<skill-dir>` is this skill's install directory (where this SKILL.md lives, e.g. `~/.claude/skills/social-video-transcript`). The helper scripts ship in `<skill-dir>/scripts/`: `ensure-model.sh`, `dl-transcribe.sh`, and the Douyin-only `douyin-parse-fallback.py`.

---

## Phase 0: Ensure the Whisper model is present (first run only)

Transcription needs the **large-v3** CoreML model on disk (~1.5 GB). Before the first run, confirm it exists (scan, don't assume):

```bash
bash "<skill-dir>/scripts/ensure-model.sh"
```

- `MODEL_PATH=<dir>`: a model was found and is reused. Export it so Phase 1 uses it directly:
  ```bash
  export WHISPER_MODEL_PATH="<dir>"
  ```
  (If you forget, `dl-transcribe.sh` re-scans via `ensure-model.sh` and still finds it; the export just skips that.)
- `MODEL_NOT_FOUND`: no large-v3 model anywhere. **Ask the user before downloading** (a ~1.5 GB Hugging Face fetch, a few minutes). On their OK:
  ```bash
  bash "<skill-dir>/scripts/ensure-model.sh" --download
  ```
  Downloads the `openai_whisper-large-v3-v20240930` snapshot, then prints `MODEL_PATH=<dir>`; export it as above. (Choose where it lands with a positional dir after `--download`, or the `WHISPER_MODELS_DIR` env var; default `~/.cache/whisperkit-models`.)

Once present, later runs find it via the scan and skip straight to Phase 1.

---

## Phase 1: Download + transcribe (one command)

Run the helper (it does pre-flight, resolve, platform-detect, download, audio extract, Whisper, and prints everything):

```bash
bash "<skill-dir>/scripts/dl-transcribe.sh" "<paste the video link or full share text here>"
```

The script prints:
- `WORKDIR=/tmp/social-video-transcript.XXXXXX`: the temp dir (remember it for cleanup)
- `PLATFORM=<douyin|xiaohongshu|instagram|facebook|tiktok|video>`
- `----META----` … a JSON block (title / uploader / duration / upload_date / counts / webpage_url / platform)
- `----RAW----` … the raw verbatim ASR transcript (one block, tokens stripped)
- `----END----`

Language is **auto-detected** by Whisper. To force a language on a noisy clip, set `WHISPER_LANG=zh` (or `en`, etc.) before the command.

**If it prints an error marker instead**, handle and stop:
- `MISSING_TOOL=<t>`: a binary is absent (`yt-dlp` / `ffmpeg` / `whisperkit-cli` / `python3`); tell the user the Homebrew install line from Requirements.
- `MISSING_MODEL=<path>`: the model isn't at the resolved path; go back to **Phase 0** (`ensure-model.sh`) to locate or download it, then re-run with `WHISPER_MODEL_PATH` exported.
- `NO_URL`: couldn't find a URL in the input; ask the user to re-paste the link.
- `DOWNLOAD_FAILED`: the video couldn't be fetched. The script already retried with cookies from several browsers (chrome / safari / firefox / edge / arc / brave) and, for Douyin links, walked the parse-API fallback chain. See "When the download is blocked" below; don't fake a transcript.
- `TRANSCRIBE_FAILED`: the download worked but whisperkit-cli failed or produced no text (corrupt/partial model, OOM, or a clip with no speech). The script keeps a `whisper.log` in the printed WORKDIR; point the user there. Often a re-run of Phase 0 `--download` (model didn't fully assemble) fixes it.

> The script also prints `WORKDIR=` on these failure paths, so you can inspect logs and clean up. Don't pre-empt with cookies unless the first try fails.

---

## Phase 2: Light-clean into readable markdown

Take the `----RAW----` text and produce a **readable** version. This is a judgment pass, not a rewrite. **First look at what language the transcript is in** and clean accordingly:

**Always:**
- **Add punctuation and paragraph breaks.** Group by idea; short clip = a few short paragraphs.
- **Preserve meaning and code-switching** (中英混排 as spoken). Do **not** add facts, opinions, or summary that aren't in the audio.
- **Fix obvious proper-noun / brand / product-name errors using the META title + description as topic context** (e.g. a mis-heard tool or company name). Correct only what's clearly wrong given the topic.
- **Flag genuine uncertainty** with `[brackets]` and one short 校对说明 / proofing-note line listing the fixes you made + any guesses. If the title is clickbait that contradicts the spoken content, note it.

**If the transcript is Chinese (Douyin / Xiaohongshu / Chinese creators):**
- Chinese Whisper especially mangles homophones (谐音) and proper nouns. Typical failure pattern: `Kithub→GitHub`, `cloud.md→CLAUDE.md`, `卡帕西→Karpathy`, `采过→踩过`. Run the homophone-correction pass against the title/topic.

**If the transcript is English or another language (Instagram / Facebook / TikTok / non-Chinese creators):**
- Do **not** apply Chinese-homophone logic. English Whisper errors are mostly proper nouns, spelled-out URLs, and mis-segmented words; fix those against the title/description.

Keep it faithful enough that the raw meaning is intact: this is the base for the user's *next* step, not a finished artifact.

### File to write

Output folder: `${OUTPUT_DIR:-${DOUYIN_OUTPUT_DIR:-$HOME/Downloads/social-video-transcripts}}` (`mkdir -p` it first).

Path: `<output-folder>/<YYYY-MM-DD>-<platform>-<title-slug>.md` (today's date; `<platform>` from the `PLATFORM=` marker; slug = title kebab-cased, drop emoji / `#hashtags` / punctuation, ~6 words max).

Formatting: No em dashes, no double dashes (--), no spaced hyphens as separators; use standard punctuation only (comma, colon, period, parentheses); restructure the sentence if needed. Preserve 中英混排, hyphen-no-space filename.

Template (use the transcript's own language for the body heading: `逐字稿（轻清洗版）` for Chinese, `Transcript (light-cleaned)` for English):

```markdown
---
title: <video title>
date: <YYYY-MM-DD>
type: social-video-transcript
platform: <platform>
source: <webpage_url>
uploader: <uploader>
duration: <duration>s
status: awaiting-next-step
tags: [<platform>, transcript]
---

# <video title>

- **Source:** <webpage_url>
- **Platform / uploader / date:** <platform> · <uploader> · <upload_date>
- **Duration:** <duration>s · likes <like_count> · shares <repost_count>

## <Transcript heading in the transcript's language>

<cleaned, punctuated, paragraphed transcript>

> **校对说明 / Proofing note:** <one line: what proper-noun / homophone fixes were made; any [bracketed] guesses; title-vs-content mismatch if any>
```

---

## Phase 3: Clean up + hand off

1. Remove the downloaded media (only the temp work dir from this run):
   ```bash
   rm -rf "<the WORKDIR printed in Phase 1>"
   ```
   Only ever `rm -rf` the `/tmp/social-video-transcript.XXXXXX` path the script printed, never the skill folder or any other path.
2. Report to the user: the output file path + a one-line gist of what the video is about.
3. **Stop. Await the next instruction.** Don't auto-summarize, translate, or repurpose unless asked.

---

## When the download is blocked (`DOWNLOAD_FAILED`)

Different platforms fail differently:

- **Douyin**: Douyin's `a_bogus` JS-VM risk-control now returns an empty response to yt-dlp regardless of cookies, TLS impersonation, or yt-dlp version, so yt-dlp can no longer resolve the video. The script handles this **automatically**: when yt-dlp fails on a Douyin link it runs `douyin-parse-fallback.py`, which walks a chain of free public "解析" (parse) APIs that execute the challenge server-side, returns Douyin's real CDN url, and downloads + extracts locally. You do nothing. It still tries yt-dlp **first** (so it self-heals if the extractor is fixed upstream); keep `yt-dlp` recent anyway (`yt-dlp -U` / `brew upgrade yt-dlp`). If `DOWNLOAD_FAILED` still prints, the whole parse chain was down (these free APIs die often); retry later, or add a new parser to the chain in `douyin-parse-fallback.py`.
- **Instagram / Facebook**: most non-public content is **login-gated**. The script auto-retries with cookies from your browsers. If it still fails, open the video once in your logged-in browser, then retry; pin the right browser with `COOKIE_BROWSER=chrome` (or `safari` / `firefox` / `edge` / `arc` / `brave`).
- **Xiaohongshu**: short `xhslink.com` links resolve fine; some posts are login-gated like IG/FB.
- Any platform: a recent `yt-dlp` matters most, extractors break and get fixed upstream constantly.

> **Privacy note on the Douyin fallback.** The parse-API path sends only the *public video URL* to a third-party "公益" (free / non-profit) parse service so it can run Douyin's JS challenge; the service hands back Douyin's own CDN url and the **video bytes download straight from Douyin's CDN, not through the parser**. It fires only for Douyin links, only as a fallback after yt-dlp fails. If you'd rather not involve a third party at all, a `DOWNLOAD_FAILED` is the honest alternative: the skill never fabricates a transcript.

---

## Notes / gotchas

- `whisperkit-cli` must use `--model-path <local model>`; bare `--model large-v3` hangs downloading from Hugging Face during a transcribe run. The scripts pin the local model path, so this is handled.
- Language is auto-detected (no `--language` passed) unless you set `WHISPER_LANG`. Whisper large-v3 detects per-clip via VAD prefill; force it only for noisy or heavily code-switched audio.
- A platform's `music` / `audio` URL is background BGM, not the voiceover; the script downloads the video and extracts the mixed track (`-x`).
- Most of these platforms expose no native subtitle track, so ASR is mandatory.
- Everything stays on your machine. Network access is limited to: the video download, the one-time model fetch from Hugging Face, and (only as a Douyin fallback after yt-dlp fails) sending the public video URL to a parse API (see the Privacy note above).
- The Douyin parse-API fallback needs no extra Python packages: it uses the system `curl` (always present on macOS) to call the parser and pull CDN bytes, then `ffmpeg` to extract audio. No `curl_cffi` / TLS-impersonation dependency.

---

## Skill metadata

- **Version**: 1.2 (2026-06-29) widened the Douyin parse-API chain to `xinyew -> devtool -> jxcxin -> tikwm` and added a short->canonical (`www.douyin.com/video/<id>`) URL fallback, after a Douyin `a_bogus` change took the whole free-parser layer down on 2026-06-29 (xinyew alone had been a single point of failure). 1.1 (2026-06-28) added the Douyin parse-API fallback (`douyin-parse-fallback.py`) for when yt-dlp can't beat `a_bogus` risk-control, plus a bounded timeout on cookie-based yt-dlp calls (stops the macOS Keychain hang). 1.0 was the initial multi-platform release (2026-06-21).
- **Vault SOT**: `04_Resources/Skills/social-video-transcript/`
- **Symlink**: `~/.claude/skills/social-video-transcript` → vault SOT
- **GitHub**: `github.com/breakthrough-edu/social-video-transcript` (`npx skills add breakthrough-edu/social-video-transcript`)
- **Supersedes**: `douyin-transcript` (retired; this is its multi-platform successor).
