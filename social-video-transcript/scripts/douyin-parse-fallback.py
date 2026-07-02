#!/usr/bin/env python3
"""douyin-parse-fallback.py <url> <workdir>

Fallback Douyin fetcher for social-video-transcript, used ONLY when yt-dlp fails.

Why this exists: Douyin's detail endpoint returns an empty body to any request that has
not executed their in-browser `a_bogus` JS challenge, so yt-dlp -- even nightly, with
browser cookies and TLS impersonation -- can no longer resolve the video URL. The only
paths that work run that JS challenge: a real browser, or a server-side "解析" (parse)
service that does it for you and hands back the real CDN url.

Strategy: walk a chain of free public parse APIs; take the first that returns a usable
CDN url; download the MP4 straight from Douyin's CDN with plain `curl` (the CDN serves
bytes to a normal UA -- no TLS impersonation / no extra Python deps needed); extract a
16kHz mono WAV with ffmpeg; write meta.json so the caller's homophone-correction pass
keeps its title context. Then dl-transcribe.sh continues with its normal local Whisper.

Free parse APIs are fragile (they rate-limit / 404 / vanish). So we try several and, if
the whole chain misses, exit non-zero and let the caller fail LOUDLY -- never fake it.
Privacy: only the public video URL transits a third-party parser; the video bytes come
straight from Douyin's CDN.

stdout: FALLBACK_OK parser=<name>   on success (audio.wav + meta.json written to workdir)
stderr: per-parser diagnostics
exit:   0 success | 1 whole chain failed | 2 bad args
"""
import sys, os, json, subprocess, urllib.parse

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")


def _curl(args, **kw):
    return subprocess.run(["curl", "-sS", "--connect-timeout", "15", *args],
                          capture_output=True, **kw)


def _api_json(url):
    r = _curl(["-A", UA, "--max-time", "30", url], text=True)
    return json.loads(r.stdout)


# --- parsers: each takes the share url, returns (cdn_video_url, meta_dict) or None ---
def p_xinyew(share_url):
    # 新野API (公益接口) -- the one proven alive in the 2026-06-28 session.
    j = _api_json("https://api.xinyew.cn/api/douyinjx?url=" + urllib.parse.quote(share_url))
    if j.get("code") != 200:
        return None
    d = j.get("data") or {}
    v = d.get("video_url") or d.get("play_url")
    if not v:
        return None
    add = d.get("additional_data") or []
    a0 = add[0] if add else {}
    return v, {"title": a0.get("desc") or d.get("desc"),
               "uploader": a0.get("nickname") or d.get("nickname")}


def p_tikwm(share_url):
    # Weak for Douyin (often "Url parsing is failed"), kept as a live-infra secondary.
    j = _api_json("https://www.tikwm.com/api/?url=" + urllib.parse.quote(share_url))
    if j.get("code") != 0:
        return None
    d = j.get("data") or {}
    v = d.get("play") or d.get("hdplay") or d.get("wmplay")
    if not v:
        return None
    if not v.startswith("http"):
        v = "https://www.tikwm.com" + v
    return v, {"title": d.get("title"),
               "uploader": (d.get("author") or {}).get("nickname"),
               "duration": d.get("duration")}


# Order = preference. Add new parsers here as old ones die (free infra has high mortality).
PARSERS = [("xinyew", p_xinyew), ("tikwm", p_tikwm)]


def main():
    if len(sys.argv) < 3:
        print("usage: douyin-parse-fallback.py <url> <workdir>", file=sys.stderr)
        return 2
    url, wd = sys.argv[1], sys.argv[2]
    mp4 = os.path.join(wd, "video.mp4")
    wav = os.path.join(wd, "audio.wav")

    for name, fn in PARSERS:
        try:
            res = fn(url)
        except Exception as e:
            print(f"  parser {name}: error {e}", file=sys.stderr)
            continue
        if not res:
            print(f"  parser {name}: no usable url", file=sys.stderr)
            continue
        vurl, meta = res

        dl = _curl(["-L", "-A", UA, "-H", "Referer: https://www.douyin.com/",
                    "--max-time", "300", "-o", mp4, vurl])
        size = os.path.getsize(mp4) if os.path.exists(mp4) else 0
        if dl.returncode != 0 or size < 10240:  # <10KB => an error page, not a video
            print(f"  parser {name}: CDN download failed (rc={dl.returncode}, size={size})",
                  file=sys.stderr)
            continue

        ff = subprocess.run(["ffmpeg", "-y", "-i", mp4, "-vn", "-ac", "1", "-ar", "16000",
                             "-c:a", "pcm_s16le", wav], capture_output=True)
        if ff.returncode != 0 or not os.path.exists(wav) or os.path.getsize(wav) < 1024:
            print(f"  parser {name}: ffmpeg extract failed", file=sys.stderr)
            continue

        # duration: prefer ffprobe on the real media; fall back to the parser-reported value
        dur = meta.get("duration")
        try:
            pr = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                 "-of", "default=nw=1:nk=1", mp4], capture_output=True, text=True)
            if pr.stdout.strip():
                dur = int(float(pr.stdout.strip()))
        except Exception:
            pass

        out = {"title": meta.get("title"), "uploader": meta.get("uploader"),
               "duration": dur, "webpage_url": url, "platform": "douyin",
               "source": f"parse-api:{name}"}
        with open(os.path.join(wd, "meta.json"), "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        try:
            os.remove(mp4)  # the caller only needs audio.wav
        except OSError:
            pass
        print(f"FALLBACK_OK parser={name}")
        return 0

    print("FALLBACK_FAILED (all parse APIs missed -- chain exhausted)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
