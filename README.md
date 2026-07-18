# MediaCtrl

A personal Windows automation layer, written in **AutoHotkey v2**, that watches what's playing on the PC (Spotify, browser video, games) and reacts automatically — auto-fullscreen on video sites, silent-outro skipping for Spotify, speaker bass EQ toggling, and a set of media/utility hotkeys.

The Spotify integration targets the native Spotify desktop app (not the web player/PWA).

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
- On YouTube, playback detection is pinned to the real player (`#movie_player`), so hovering a thumbnail's autoplay preview elsewhere on the page can't be mistaken for the video actually playing.
- While in this "video mode": `w a s d` map to player navigation, `1 2 3 4` set playback speed, `0` seeks to the start, `Esc`/`b` toggle fullscreen, clicking the video (`LButton`) exits fullscreen without exiting on clicks that land on player controls (settings, volume, etc. — detected by comparing the clicked element's size against the video's, not by hardcoded site-specific classes), `F5` exits fullscreen and reloads the page, and `F8` jumps to the next episode by reading a page's "next" link.
- `F7` toggles video-mode monitoring on/off entirely (exits fullscreen if currently in it).

**Volume leveler**
- Reactively attenuates the browser's per-app WASAPI volume while watching a matched site, smoothing out videos that are recorded louder/quieter than each other so they sound roughly consistent as you scroll a feed.
- Attenuation-only (can turn a loud video down, never boost a quiet one past its own peak) — tuned via `CONFIG.VOLUME_LEVELER_*` (target peak, smoothing, step size, floor).
- Resets the browser back to full volume once you're not on a matched site, so it doesn't stay quiet for unrelated tabs.

**Fullscreen clock overlay**
- A small, click-through clock in the top-right corner while in fullscreen video, filling the gap left by Windows' taskbar clock being hidden.

**Spotify silent-outro skipping**
- Polls WASAPI peak metering for the native Spotify app (`Spotify.exe`) and auto-skips to the next track if audio is playing but silent in the last 10 seconds of a track — catches silent outros that don't change Spotify's reported playback status.
- Debounced against manual track changes (keyboard, mouse, phone) so a real skip doesn't get misread as a false outro trigger.

**Speaker / bass EQ**
- Detects the active playback device once at startup.
- If it's a specific speaker, toggles a bass-boost EQ preset (via Peace/EqualizerAPO hotkeys) on/off depending on whether a specific game is the focused, running window.
- If it's a different specific speaker, arms a one-shot 30-minute check that shuts the PC down if that speaker is no longer present (i.e. got unplugged/switched).

**Hotkeys & system glue**
- Media key remaps (play/pause, skip, a forced shutdown bound to one of the keys — careful with that one).
- Volume and brightness key forwarding (PgUp/PgDn, Home/End → a brightness tool).
- `F6` toggles a live on-screen debug tooltip: current program/URL, browser playback, video-hotkey status, playable tabs, speaker/bass, volume leveler, and Spotify timeline/WASAPI session info.
- `F9`/`F10` manually force the bass EQ off/on.
- `Ctrl+W` exits fullscreen state cleanly before letting the browser close the tab.
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
| `SONG_EXE` | Native Spotify executable name, used to activate/launch it when no SMTC session exists yet (e.g. `Spotify.exe`) |
| `SITES` | Per-site fullscreen behavior — fullscreen key, mouse centering, startup delay, hold-to-seek, iframe handling |
| `GAME_LIST` | Process names that trigger bass-on behavior when focused |
| `TIMER_ACTIVE` / `TIMER_IDLE` | Polling interval (ms) while media is/isn't active |
| `URL_MISS_DEBOUNCE` | Consecutive ticks a URL must be missing from playable tabs before treating the tab as left |
| `LOSSLESS_HOTKEY` | Key sent to toggle Lossless Scaling |
| `VOLUME_LEVELER_ENABLED` | Master on/off for the volume leveler |
| `VOLUME_LEVELER_TARGET` / `_MIN` | Target smoothed peak and attenuation floor (0.0–1.0) |
| `VOLUME_LEVELER_SMOOTHING` / `_STEP` / `_INTERVAL` | EMA smoothing factor, max change per sample, sample interval (ms) |

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
| `Audio.ahk` | Spotify outro detection (WASAPI peak metering), browser volume leveler, playback controls |
| `Speaker.ahk` | Startup speaker detection, bass EQ, Adam D3V shutdown watchdog |
| `Bridge.ahk` | Spawns and talks to the Node.js WebSocket/HTTP bridge |
| `Hotkeys.ahk` | Static (always-on) hotkeys, including the video-click-to-exit-fullscreen handler |
| `UI.ahk` | Debug tooltip and the fullscreen clock overlay |
| `Lib/Media.ahk` | AHK wrapper around Windows' `GlobalSystemMediaTransportControlsSessionManager` |
| `Extension/content.js` | Injected into every frame — detects the active `<video>`, reports playback/URL/click state to the bridge, and executes commands (seek, speed) sent from AHK |
| `Extension/background.js` | MV3 service worker — owns the WebSocket connection to the bridge, tracks tabs/frames, and routes commands to the right tab |
| `Extension/manifest.json` | Chrome extension manifest (MV3) |
| `mediactrl_bridge.js` | Auto-generated by `Bridge.ahk` at runtime — not meant to be edited directly |