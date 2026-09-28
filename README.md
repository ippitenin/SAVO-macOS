<p align="center">
  <img src="Savo-app/Resources/AppIcon.png" alt="Savo" width="160">
</p>

<h1 align="center">Savo for macOS</h1>

<p align="center">
  A native macOS app for downloading your own YouTube videos:
  paste a link, pick the quality, get the file.
</p>

<p align="center">
  <b>English</b> · <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-orange">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

Savo was made for one job: saving videos from your own YouTube channel — public and
unlisted streams included — without a terminal. The download engine (yt-dlp with
ffmpeg and deno) ships inside the app, so there is nothing to install with Homebrew
or Python.

The interface is localised in English and Russian; the code and its comments are
written in Russian.

## Features

- **Paste a link** — a card with the thumbnail, title, channel and duration appears.
  Picking a YouTube link up from the clipboard when you switch to Savo is optional
  (off by default).
- **Three kinds of downloads** — *Video* (MP4 with sound), *Audio* (original M4A or
  MP3 at 320/192/128 kbps) and *Muted* (video track only). Only the qualities the
  video really has are offered, with an estimated file size.
- **Quality named the way YouTube names it** — 2160p … 360p, also for non-16:9 and
  vertical videos (a 3840×1920 video is “2160p”, not “1920p”). The format selector is
  strict: if YouTube does not serve the chosen quality, Savo says so instead of
  silently downloading a lower one.
- **Opens in QuickTime** — the default is the highest H.264 variant; qualities that
  exist only as VP9/AV1 are marked.
- **Readable file names** — `Title [28.09.2026, 1080p].mp4`: the upload date tells
  same-titled streams apart, and different qualities of one video never overwrite
  each other.
- **Progress** with speed, time left and phases (video → audio → merging). Cancelling
  cleans up temporary files; partial downloads never land in your Downloads folder.
- **History** of recent downloads with “Show in Finder”; it survives restarts and
  tolerates a damaged record instead of losing everything.
- **An engine that stays fresh** — once a day Savo checks GitHub for a new yt-dlp,
  verifies its SHA-256 and swaps it in atomically, never in the middle of a
  download. “Update engine” in Settings does the same on demand.
- **Clear errors** — when YouTube refuses (403, “not a bot”, missing format) Savo
  retries with another player client first; rate limits and private videos get
  their own messages.
- **Diagnostics** — “Copy debug report” in Settings (versions, Mac model, engine
  start-up time, recent downloads, log tail) and the engine log at
  `~/Library/Logs/Savo/engine.log`.
- **Current macOS look** — Liquid Glass on macOS 26/27, a material fallback on 14/15,
  light and dark themes, Reduce Motion and Reduce Transparency respected.

## Requirements

- A Mac with Apple Silicon (M1 or newer), macOS 14 Sonoma or later. Intel Macs are
  not supported.
- To build: Xcode with the macOS 26 SDK or newer (the current system look depends on
  the SDK the app is built with) and an internet connection for the engine download.

## Building

```bash
cd Savo-app
scripts/fetch-binaries.sh   # yt-dlp (onedir), ffmpeg, deno → Vendor/bin (not in git)
./build.sh                  # arm64 build, signing, install to ~/Applications
./build.sh --zip            # the same plus Savo.zip for another Mac
./run.sh                    # build and launch
```

- `fetch-binaries.sh` checks the yt-dlp archive against the release `SHA2-256SUMS`
  and makes sure every binary has an arm64 slice. Pin a yt-dlp version with
  `YTDLP_TAG=2026.08.19 scripts/fetch-binaries.sh`.
- Signing uses a local “Savo Dev” certificate if you have one
  (`scripts/make-dev-cert.md`), otherwise ad-hoc. On another Mac the first launch
  needs right-click → Open (or System Settings → Privacy & Security → Open Anyway).
- `build.sh` assembles the bundle in `/tmp` (iCloud Desktop folders attach extended
  attributes that break `codesign`) and rewrites the SDK version in the binary's
  `LC_BUILD_VERSION`: SwiftPM records the deployment target there, and macOS would
  otherwise give the app its old-style controls.

## How it works

- **AppKit shell, SwiftUI content.** `DownloadController` is a small state machine:
  idle → fetching info → ready → downloading → done / failed.
- **Engine.** The bundle carries yt-dlp as the upstream onedir archive. On first
  launch it is unpacked into `~/Library/Application Support/Savo/bin`, test-run and
  used from there — the onedir build starts in ~0.2 s, the one-file build took ~7 s
  on every launch. Updates replace the whole folder with a single atomic rename.
  Every external process goes through `ProcessRunner`.
- **Layout** (`Savo-app/Sources/Savo`):
  - `Engine/` — installer, updater, process runner, yt-dlp client, progress parser,
    errors, engine log;
  - `Model/` — link validation, video info, quality presets (pure logic);
  - `Controllers/` — the download state machine;
  - `Storage/` — history and settings;
  - `Diagnostics/` — the debug report;
  - `UI/` — windows and views, `UI/DesignSystem/` — design tokens, glass, buttons.

Developer notes and the pitfalls we already hit live in [`CLAUDE.md`](CLAUDE.md)
(in Russian).

## Third-party components

Downloaded by `scripts/fetch-binaries.sh` at build time and bundled into the app;
they are not stored in this repository.

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — Unlicense (public domain).
- [FFmpeg](https://ffmpeg.org) — static builds from
  [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de); LGPL/GPL depending on the
  build configuration.
- [Deno](https://deno.com) — MIT.

## Responsible use

Savo is meant for content you own or have permission to download, such as your own
channel. Respect YouTube's Terms of Service and copyright.

## License

[GPL-3.0](LICENSE).
