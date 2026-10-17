# MediaCtrl

A personal Windows automation layer, written in **AutoHotkey v2**, that watches what's playing on the PC (Spotify, browser video, games) and reacts automatically — auto-fullscreen on video sites, Lossless Scaling that follows fullscreen, silent-outro skipping for Spotify, speaker bass EQ toggling, and a set of media/utility hotkeys.

The Spotify integration targets the native Spotify desktop app (not the web player/PWA).

It's made of three pieces. The AHK script and the Chrome extension both connect to a small Node relay over WebSockets on `127.0.0.1:9224`; there is no HTTP port and no temp files:

```
┌─────────────┐  WebSocket   ┌──────────────────┐  WebSocket   ┌─────────────┐
│   Chrome    │ ───────────> │   Node bridge    │ <─────────── │   AHK v2    │
│  extension  │ <─────────── │ bridge/bridge.js │ ───────────> │   script    │
└─────────────┘  page state  └──────────────────┘   commands   └─────────────┘
                 (+ token)       127.0.0.1:9224      (+ token)     SMTC / WASAPI
```

- **AHK script** — the brain. Decides when to enter/leave fullscreen, when the video keys are on, and when to toggle Lossless Scaling, using pure, tested rule modules (`Lib/Decide.ahk`, `Lib/FsMachine.ahk`, `Lib/LosslessPolicy.ahk`). Also owns Spotify (SMTC + WASAPI), the volume leveler, and all the hotkeys.
- **Node bridge** (`bridge/bridge.js`) — relays JSON between the two. Every client must open with `hello` and the shared token; extension clients also need a `chrome-extension://` origin. One client per role; a second copy of the extension is refused while the first is alive. The token is never sent outward.
- **Chrome extension (MV3)** — reports the active tab's video state (site, playable, playing, ready, fullscreen, typing) and runs fullscreen/seek/speed inside the page. Site settings come from `Config.ahk`.

## Features

**Page-tracked fullscreen (no guessing)**
- Fullscreen state comes from the page itself (`fullscreenchange`), never from counting keypresses.
- Entering: once the video is playing and its player is ready, AHK arms the page and presses **F19**; the page clicks the site's own fullscreen button (falling back to `requestFullscreen()` on the player, then to the site's key). Exiting goes through `document.exitFullscreen()` — no toggle key.
- Each request gets one confirmation window (1 s) and one retry, then gives up and trusts the page's last report.
- Exits you make yourself — `Esc`, `b`, clicking the video, the site's button, double-click, Chrome's own Esc — count as a **manual exit**: that video won't auto-re-enter until playback stops, also after switching apps or tabs and coming back. A different video still auto-enters. Reloading the page or closing the tab is not a manual exit.
- Clicking the video in fullscreen: the site pauses it, then fullscreen exits (at most 0.5 s later). `b` while playing does the same via Space.
- Leaving a playable page needs 3 consecutive ticks of "not playable", so Douyin's feed swapping `<video>`s doesn't cause false exits.
- YouTube and Bilibili only count the video inside the real player, so hover previews never count.

**Lossless Scaling follows fullscreen**
- Turns on when a video's fullscreen is confirmed and off when it ends — so F5, Ctrl+W, the site button and double-click all switch it off through the page's report.
- The Lossless key is only ever sent while Chrome is the foreground app; a change confirmed while Chrome isn't in front waits until it is.
- Scaling state is detected from Lossless Scaling's overlay window — only an overlay over Chrome's monitor counts — so the key is only sent when the state actually differs. F1/F2/F3 (video mode) still toggle it by hand; the next automatic change goes the right way.
- After an AHK reload mid-fullscreen, scaling is assumed to still be on (no extra toggle).

**Typing passes through**
- Video keys turn off while a text field has focus — including fields inside shadow roots (Bilibili comments) and iframes (YouTube live chat) — and while Chrome's own UI has focus (address bar, find bar, dialogs).

**Video mode keys** (only while watching a video on a matched site in Chrome)
- `w a s d` → arrow keys. A tap of `d` or Right seeks as usual; **holding** `d` or Right plays the video at 2× until you let go, on every site (YouTube included).
- `e` / `q` skip ±87 s, `0` restarts, `1 2 3 4 5` set speed 1×/1.5×/2×/3×/0.5×.
- `Esc` toggles fullscreen; `b` pauses and exits (or enters when not fullscreen).
- `F1 F2 F3` → Lossless Scaling hotkey passthrough.
- `F7` toggles video-mode monitoring on/off entirely (exits fullscreen if currently in it).

**Page leveler (every video at the same loudness)**
- Runs inside the page: each video's loudness is measured over a few seconds and its gain moved toward one target level — quiet videos are turned up, loud ones down (±18 dB by default) — with a limiter catching peaks. Gaps and silence hold the gain; a new video starts from the last one's gain and settles within about a second.
- Only attaches to video sources Web Audio can process (YouTube/Bilibili's streaming players, same-origin media), because anything else would play silent. Tuned via `CONFIG.PAGE_LEVELER`.

**Volume leveler (fallback)**
- Used only on pages where the page leveler couldn't attach. Reactively attenuates the browser's per-app WASAPI volume while a matched site is playing, smoothing out videos that are recorded louder/quieter than each other so they sound roughly consistent as you scroll a feed.
- Attenuation-only (can turn a loud video down, never boost a quiet one past its own peak) — tuned via `CONFIG.VOLUME_LEVELER_*` (target peak, smoothing, step size, floor).
- Resets the browser back to full volume once you're not watching, so it doesn't stay quiet for unrelated tabs.

**Fullscreen clock overlay**
- A small, click-through clock in the top-right corner of Chrome's monitor while in fullscreen video, filling the gap left by Windows' taskbar clock being hidden.

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
- `F6` toggles a compact status tooltip: the video (site, playing, fullscreen), whether the video keys are on, Lossless Scaling, which leveler is handling the volume, speaker/bass, and Spotify's time left. Problems (extension not connected, fullscreen gave up, waiting for the player, volume errors) show only when they happen.
- `F9`/`F10` manually force the bass EQ off/on.
- A watchdog that closes Lossless Scaling when a GPU-heavy app (LM Studio) is running.

Removed in the page-tracked rewrite: `F5` (in video mode — Chrome's own F5 reloads, and Lossless switches off through the page's report), `F8` (next episode), the `LButton` click hook (the extension reports clicks), and the `Ctrl+W` state hack (closing the tab is reported as a page change).

## Requirements

- Windows 10/11
- [AutoHotkey v2](https://www.autohotkey.com/)
- [Node.js](https://nodejs.org/) + npm (the AHK script installs the bridge's `ws` package on first run if missing)
- Google Chrome (or any Chromium browser that supports MV3 extensions)

## Setup

1. **Run the AHK script** — open `Main.ahk` with AutoHotkey v2. This will:
   - create the shared token (`mediactrl_token.txt`) and write `Extension/token.json` — both automatic and gitignored;
   - start the Node bridge (`bridge/bridge.js`, installing `bridge/node_modules` on first run) and connect to it;
   - initialize speaker detection and bass EQ, and register the hotkeys.
2. **Install the Chrome extension in one Chrome profile only** — go to `chrome://extensions`, enable Developer Mode, click "Load unpacked," and select the `Extension/` folder. (A second copy in another profile is refused by the bridge while the first is connected.)
3. The extension reads `token.json` and connects to the bridge by itself (within ~30 s of AHK starting; it retries every 2 s while disconnected).

Exiting or reloading the script closes only its own bridge process — other `node.exe` processes are left alone.

## Tests

From the repo root (PowerShell):

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut tests\RunTests.ahk   # rule modules: "N passed, M failed", exit 1 on failure
node --test bridge/ tests/js/                                                          # bridge relay + extension page logic
```

- `tests/RunTests.ahk` runs `tests/Test*.ahk`: the fullscreen rules (`Decide`), the fullscreen state machine (`FsMachine`) and the Lossless policy.
- `bridge/bridge.test.mjs` covers the token/origin checks, relaying, config hand-off and the one-extension rule; `tests/js/pageLogic.test.js` covers the extension's pure page helpers.
- Results of the hands-on checks (F19 activation, Lossless detection, hotkey responsiveness, per-site behaviour) are in `docs/windows-checks.md`.

## Configuration

All user-specific values live in `Config.ahk`:

| Setting | Purpose |
|---|---|
| `SONG` / `BROWSER` | Process name fragments used to match SMTC/WASAPI sessions (e.g. `spotify`, `chrome`) |
| `SONG_EXE` | Native Spotify executable name, used to activate/launch it when no SMTC session exists yet (e.g. `Spotify.exe`) |
| `SITES` | Per-site settings, sent to the extension: domain, the site's fullscreen button, the player container, the fallback fullscreen key |
| `TICK_MS` | Video evaluation timer (ms) |
| `SEEK_SECONDS` / `SPEEDS` | `e`/`q` jump size, and the `1 2 3 4 5` playback speeds |
| `HOLD_SPEED` / `HOLD_TAP_MS` | Rate while `d`/Right is held, and how short a press counts as a tap |
| `CLICK_EXIT_WAIT_MS` | How long `b`/a video click waits for the site's pause before exiting anyway |
| `GAME_LIST` | Process names that trigger bass-on behavior when focused |
| `TIMER_ACTIVE` / `TIMER_IDLE` | Main tick interval (ms) while media is/isn't active |
| `LOSSLESS_HOTKEY` | Key sent to toggle Lossless Scaling |
| `BRIDGE_PORT` | The bridge's WebSocket port (127.0.0.1 only) |
| `PAGE_LEVELER` | The in-page loudness leveler: on/off, target level, max boost/cut, averaging time, silence and limiter levels |
| `VOLUME_LEVELER_ENABLED` | Master on/off for the fallback (WASAPI) volume leveler |
| `VOLUME_LEVELER_TARGET` / `_MIN` | Target smoothed peak and attenuation floor (0.0–1.0) |
| `VOLUME_LEVELER_SMOOTHING` / `_STEP` / `_INTERVAL` | EMA smoothing factor, max change per sample, sample interval (ms) |

## ⚠️ This is a personal config, not a general-purpose tool

This repo reflects one specific desk setup, and several pieces are hardcoded rather than configurable:

- Absolute install paths (`C:\Program Files\...`) for Equalizer APO/Peace, Lossless Scaling, and a specific game.
- Speaker logic keyed to specific hardware names (`Harman Kardon`, `Adam D3V`), including a **shutdown-on-disconnect** behavior for the latter.
- A media key (`Media_Prev`) is remapped to force a shutdown.
- F19 is used as the "fullscreen now" nudge, so it must be free on this PC.

If you're adapting this for your own use, start with `Config.ahk` and `Hotkeys.ahk`, and double-check anything in `Speaker.ahk` / `Video.ahk` that references specific hardware, paths, or processes before running it.

## File overview

| File | Responsibility |
|---|---|
| `Main.ahk` | Entry point — startup sequence, timers, exit handler |
| `Config.ahk` | All user-tunable settings, including the video sites |
| `State.ahk` | Shared global state object |
| `StateEngine.ahk` | Program/Spotify state, and the video glue: page reports → rules → fullscreen requests, Lossless, video keys on/off |
| `Video.ahk` | Game/LM Studio monitors, video-mode hotkey handlers |
| `Audio.ahk` | Spotify outro detection, browser volume leveler, playback controls |
| `Wasapi.ahk` | The one WASAPI audio-session loop shared by `Audio.ahk` |
| `Speaker.ahk` | Startup speaker detection, bass EQ, Adam D3V shutdown watchdog |
| `Bridge.ahk` | Token, `Extension/token.json`, starting/killing the Node bridge |
| `BridgeClient.ahk` | AHK's WebSocket client to the bridge (connect, send, reconnect) |
| `Hotkeys.ahk` | Static (always-on) hotkeys |
| `UI.ahk` | Debug tooltip and the fullscreen clock overlay |
| `Lib/Decide.ahk` | Pure rules: enter/exit fullscreen, video keys on/off, manual exit per page |
| `Lib/FsMachine.ahk` | Pure fullscreen state machine: requests confirmed only by page reports |
| `Lib/LosslessPolicy.ahk` | Pure Lossless Scaling on/off rules |
| `Lib/LosslessDetect.ahk` | Detects whether Lossless Scaling is currently scaling on a monitor (its overlay window) |
| `Lib/Screen.ahk` | Pure monitor geometry: which monitor a window is on, overlay coverage, corner positions |
| `Lib/Media.ahk` | AHK wrapper around Windows' `GlobalSystemMediaTransportControlsSessionManager` |
| `Lib/WebSocket.ahk`, `Lib/JSON.ahk` | Vendored from [thqby/ahk2_lib](https://github.com/thqby/ahk2_lib) (MIT, `Lib/ahk2_lib-LICENSE.txt`) |
| `bridge/bridge.js` | The Node WebSocket relay (`bridge/package.json` holds its `ws` dependency) |
| `Extension/content.js` | Runs in each page — finds the active `<video>`, reports its state, runs fullscreen (F19 nudge)/seek/speed/hold-to-speed, reports clicks on the video |
| `Extension/lib/pageLogic.js` | Pure page helpers (site matching, watch-page URLs, typing detection, leveler maths), unit-tested |
| `Extension/background.js` | MV3 service worker — the bridge connection; forwards only the active tab's reports and routes commands to it |
| `Extension/manifest.json` | Chrome extension manifest (MV3) |
| `tests/` | AHK test runner + rule-module tests, and the node test for `pageLogic.js` |
| `docs/windows-checks.md` | Results of the hands-on Windows checks |
