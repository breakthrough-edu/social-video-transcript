# social-video-transcript

Turn a short-video link -- **Douyin (抖音)**, **Xiaohongshu / RED (小红书)**, **Instagram**, **Facebook**, or **TikTok** -- into a clean, readable **markdown transcript**. Fully local, free, on Apple Silicon macOS.

Paste a link (or the full share text). The skill downloads the video, transcribes it locally with **Whisper large-v3** on the Apple Neural Engine (auto-detecting the language), light-cleans the raw speech-to-text into readable prose (fixing the homophone / proper-noun mistakes Whisper makes, using the video's own title as context), and saves one `.md` file. Nothing leaves your machine.

This is a [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) skill. It is the multi-platform successor to `douyin-transcript`.

## Install

```bash
npx skills add breakthrough-edu/social-video-transcript
```

Then, in Claude Code, paste a supported-platform link and it takes over.

## Supported platforms

Anything [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) can fetch works. Verified extractors:

| Platform | Notes |
|---|---|
| Douyin (抖音) | `a_bogus` risk-control now blocks yt-dlp -- the skill auto-falls-back to a parse-API chain |
| Xiaohongshu / RED (小红书) | `xhslink.com` short links resolve fine |
| Instagram | reels + posts; non-public usually needs login cookies |
| Facebook | video + reels; often needs login cookies |
| TikTok | public videos |

A link from any other yt-dlp-supported site also runs (labelled `video`).

## Requirements (Apple Silicon macOS only)

Transcription uses [`whisperkit-cli`](https://github.com/argmaxinc/WhisperKit) (CoreML / Apple Neural Engine), so this runs on **Apple Silicon Macs**. Install the tools with [Homebrew](https://brew.sh/):

```bash
brew install whisperkit-cli ffmpeg yt-dlp
```

| Tool | Why |
|---|---|
| `whisperkit-cli` | local Whisper transcription on the Neural Engine |
| `ffmpeg` | extract + resample the audio to 16kHz mono WAV |
| `yt-dlp` | resolve + download the video |
| `python3` | strip ASR tokens, collect metadata (Homebrew pulls it in automatically as a `yt-dlp` dependency) |

On first use the skill checks for the **large-v3** model (~1.5 GB). If you don't have it, it asks before downloading `openai_whisper-large-v3-v20240930` from Hugging Face into `~/.cache/whisperkit-models` (override with `WHISPER_MODELS_DIR`). If you already have a large-v3 CoreML model (e.g. from `meeting-scribe` or `douyin-transcript`), it is detected and reused.

> Not on Apple Silicon? `whisperkit-cli` won't run. Use a cross-platform Whisper engine (faster-whisper, whisper.cpp) instead.

## Usage

Paste any of these and the skill runs:

- a full link -- `https://www.instagram.com/reel/XXXX/`, `https://www.douyin.com/video/123…`, `https://www.facebook.com/reel/XXXX`, `https://www.xiaohongshu.com/explore/XXXX`, `https://www.tiktok.com/@user/video/123…`
- a short link -- `https://v.douyin.com/XXXX/`, `https://xhslink.com/XXXX`, `https://fb.watch/XXXX`
- the whole share blob (e.g. the `复制打开抖音…` text) -- the link is extracted out of it

It downloads, transcribes (~12s for a 44s clip), light-cleans, and writes the file -- then stops and waits for your next instruction (it does **not** auto-summarize or repurpose).

## What you get

One markdown file in `~/Downloads/social-video-transcripts/` (override with `OUTPUT_DIR`):

```markdown
---
title: Video by jasoncooperson
date: 2026-06-21
type: social-video-transcript
platform: instagram
source: https://www.instagram.com/reel/XXXX/
uploader: Jason Cooperson
duration: 101s
status: awaiting-next-step
tags: [instagram, transcript]
---

# Video by jasoncooperson

- **Source:** https://www.instagram.com/reel/XXXX/
- **Platform / uploader / date:** instagram · Jason Cooperson · 20260528
- **Duration:** 101s · likes 2511 · shares --

## Transcript (light-cleaned)

Claude Code can now automatically post all your content…

> **Proofing note:** fixed `Cloud Code → Claude Code`, `Xernio → Zernio` (against the caption).
```

The transcript is a faithful, lightly-cleaned base for whatever you do next (summary, notes, repurposing) -- not an over-polished rewrite.

## Configuration

| Env var | Default | What |
|---|---|---|
| `OUTPUT_DIR` | `~/Downloads/social-video-transcripts` | where the `.md` is saved (`DOUYIN_OUTPUT_DIR` still honored) |
| `WHISPER_LANG` | (auto-detect) | force a Whisper language hint (e.g. `zh`, `en`) instead of auto-detecting |
| `WHISPER_MODEL_PATH` | (auto-detected) | explicit path to a large-v3 CoreML model dir |
| `WHISPER_MODELS_DIR` | `~/.cache/whisperkit-models` | where to keep / download models |
| `COOKIE_BROWSER` | (tries several) | force one browser for the download cookie retry (`DOUYIN_COOKIE_BROWSER` still honored) |

## When the download is blocked

Different platforms fail differently:

- **Douyin** -- Douyin's `a_bogus` JS-VM risk-control now returns nothing to yt-dlp (cookies, TLS impersonation, and nightly builds all fail), so the skill **automatically falls back** to a chain of free public parse APIs that run the challenge server-side, then downloads from Douyin's own CDN. You don't do anything. yt-dlp is still tried first, so it self-heals if the extractor is fixed upstream -- keep it recent (`yt-dlp -U` / `brew upgrade yt-dlp`). If it still fails, every parser in the chain was down (free APIs die often); retry later.
- **Instagram / Facebook** -- most non-public content is **login-gated**. The skill auto-retries with cookies from your browsers (Chrome, Safari, Firefox, Edge, Arc, Brave). If it still fails, open the video once in your logged-in browser, then retry; pin one with `COOKIE_BROWSER=chrome`.
- Any platform: a recent `yt-dlp` matters most -- extractors break and get fixed upstream constantly.

## Privacy

Everything runs on your machine. The video, the audio, and the transcript never leave it. Network access is limited to the video download and the one-time model fetch from Hugging Face.

One exception: the **Douyin parse-API fallback**. Because Douyin's `a_bogus` risk-control blocks yt-dlp, a Douyin link that yt-dlp can't fetch is sent (URL only) to a third-party "公益" / free parse service that runs Douyin's challenge and returns the real CDN url. The video bytes still download straight from Douyin's CDN, not through the parser, and this only happens for Douyin links after yt-dlp fails. If you'd rather not involve any third party, the skill failing loudly is the alternative -- it never fabricates a transcript.

## License

MIT -- see [LICENSE](LICENSE).
