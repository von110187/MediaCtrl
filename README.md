# MediaCtrl

A personal Windows automation layer, written in **AutoHotkey v2**, that watches what's playing on the PC (Spotify, browser video, games) and reacts automatically — auto-fullscreen on video sites, silent-outro skipping for Spotify, speaker bass EQ toggling, and a set of media/utility hotkeys.

It's made of three pieces that talk to each other:

```
┌─────────────┐   WebSocket (9224)   ┌───────────────────┐   SMTC / WASAPI   ┌─────────────┐
│   Chrome    │ <──────────────────> │  Node.js bridge   │ <───────────────> │   AHK v2    │
│  extension  │   HTTP    (9223)     │ (mediactrl_bridge)│                   │   script    │
└─────────────┘ <──────────────────> └───────────────────┘                   └─────────────┘
```

- **AHK script** — the brain. Polls/subscribes to Windows' System Media Transport Controls (SMTC) for playback state, reacts to it, and owns all the hotkeys.
- **Node bridge** — a tiny WebSocket + HTTP server, spawned by the AHK script on startup, that relays state between AHK and the browser (AHK can't talk to Chrome directly).
- **Chrome extension (MV3)** — reports the active tab's URL and whether it contains a `<video>`/`<audio>` element, and executes commands (fullscreen key, playback speed) sent from AHK.

## Features

**Browser video automation**
- Auto-enters fullscreen (via a per-site key, e.g. `f` or `h`) when a matched site starts playing in a tab with a real media element, and exits automatically when playback stops.
- Site-specific quirks handled via config: mouse re-centering before fullscreen, first-visit startup delay (for slow-loading players), "hold to seek" behavior (Bilibili/Douyin style), and iframe-embedded players that the content script can't see into directly.
- While in this "video mode," `w a s d` map to player navigation, `1 2 3 4` set playback speed, `Esc`/`b` toggle fullscreen, and `F8` jumps to the next episode by reading a page's "next" link.

**Spotify silent-outro skipping**
- Polls WASAPI peak metering for the browser process hosting Spotify (PWA, no dedicated `.exe`) and auto-skips to the next track if audio is playing but silent in the last 10 seconds of a track — catches silent outros that don't change Spotify's reported playback status.
- Debounced against manual track changes (keyboard, mouse, phone) so a real skip doesn't get misread as a false outro trigger.

**Speaker / bass EQ**
- Detects the active playback device once at startup.
- If it's a specific speaker, toggles a bass-boost EQ preset (via Peace/EqualizerAPO hotkeys) on/off depending on whether a specific game is the focused, running window.
- If it's a different specific speaker, arms a one-shot 30-minute check that shuts the PC down if that speaker is no longer present (i.e. got unplugged/switched).

**Hotkeys & system glue**
- Media key remaps (play/pause, skip, a forced shutdown bound to one of the keys — careful with that one).
- Volume and brightness key forwarding (PgUp/PgDn, Home/End → a brightness tool).
- A toggleable on-screen debug tooltip (`F6`) showing live state: current program/URL, browser playback, video-hotkey status, playable tabs, speaker/bass, and Spotify timeline/WASAPI session info.
- A "Lossless Scaling" hotkey passthrough, and a watchdog that closes Lossless Scaling when a GPU-heavy app (LM Studio) is running.

## Requirements

- Windows 10/11
- [AutoHotkey v2](https://www.autohotkey.com/)
- [Node.js](https://nodejs.org/) + npm (the AHK script auto-installs the `ws` package on first run if missing)
- Google Chrome (or any Chromium browser that supports MV3 extensions)

## Setup

1. **Install the Chrome extension**
   - Go to `chrome://extensions`, enable Developer Mode, click "Load unpacked," and select the `Extension/` folder.
2. **Run the AHK script**
   - Open `Main.ahk` with AutoHotkey v2. This will:
     - Initialize speaker detection and bass EQ.
     - Start the Node bridge (`mediactrl_bridge.js` — auto-generated next to the script on every launch, and `node_modules` is installed automatically on first run).
     - Register hotkeys and the media-session monitor.
3. The extension connects to the bridge over `ws://127.0.0.1:9224` automatically once both are running.

## Configuration

All user-specific values live in `Config.ahk`:

| Setting | Purpose |
|---|---|
| `SONG` / `BROWSER` | Process name fragments used to match SMTC sessions (e.g. `spotify`, `chrome`) |
| `SITES` | Per-site fullscreen behavior — fullscreen key, mouse centering, startup delay, hold-to-seek, iframe handling |
| `GAME_LIST` | Process names that trigger bass-on behavior when focused |
| `TIMER_ACTIVE` / `TIMER_IDLE` | Polling interval (ms) while media is/isn't active |
| `LOSSLESS_HOTKEY` | Key sent to toggle Lossless Scaling |

## ⚠️ This is a personal config, not a general-purpose tool

This repo reflects one specific desk setup, and several pieces are hardcoded rather than configurable:

- Absolute install paths (`D:\Program Files\...`) for Equalizer APO/Peace, Lossless Scaling, and a specific game.
- Speaker logic keyed to specific hardware names (`Harman Kardon`, `Adam D3V`), including a **shutdown-on-disconnect** behavior for the latter.
- A media key (`Media_Prev`) is remapped to force a shutdown.
- One video site (`cycani.org`) is a niche anime streaming site set up with iframe-player handling.

If you're adapting this for your own use, start with `Config.ahk` and `Hotkeys.ahk`, and double-check anything in `Speaker.ahk` / `Video.ahk` that references specific hardware, paths, or processes before running it.

## File overview

| File | Responsibility |
|---|---|
| `Main.ahk` | Entry point — startup sequence, timers, exit handler |
| `Config.ahk` | All user-tunable settings |
| `State.ahk` | Shared global state object |
| `StateEngine.ahk` | Single point of truth for state transitions (program/URL/media/fullscreen logic) |
| `Video.ahk` | SMTC event registration, game/LM Studio monitors, video-mode hotkey handlers |
| `Audio.ahk` | Spotify outro detection (WASAPI peak metering), playback controls |
| `Speaker.ahk` | Startup speaker detection, bass EQ, Adam D3V shutdown watchdog |
| `Bridge.ahk` | Spawns and talks to the Node.js WebSocket/HTTP bridge |
| `Hotkeys.ahk` | Static (always-on) hotkeys |
| `UI.ahk` | Debug tooltip |
| `Lib/Media.ahk` | AHK wrapper around Windows' `GlobalSystemMediaTransportControlsSessionManager` |
| `Extension/` | MV3 Chrome extension (`background.js`, `content.js`, `manifest.json`) |
| `mediactrl_bridge.js` | Auto-generated by `Bridge.ahk` at runtime — not meant to be edited directly |