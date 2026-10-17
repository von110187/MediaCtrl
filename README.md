# MediaCtrl

A personal Windows automation layer, written in **AutoHotkey v2** with a small Chrome extension. It watches what's playing and reacts:

- **Video** on YouTube, Bilibili and Douyin goes fullscreen by itself, gets keyboard controls, and plays at an even loudness from video to video.
- **Lossless Scaling** can follow video fullscreen, switching on and off with it.
- **Spotify**: silent outros are skipped automatically.
- **Extras** you can switch on per PC: volume/brightness/media keys, and a bass EQ that follows a game.

## Quick start

**Needs:** Windows 10/11, [AutoHotkey v2](https://www.autohotkey.com/), [Node.js](https://nodejs.org/) with npm, and Google Chrome.

1. **Run `Main.ahk`** with AutoHotkey v2 (as administrator if you want the keys to work in elevated windows too). On first run it creates everything it needs: this PC's settings file, the shared token, and the bridge's `node_modules` (needs internet once).
2. **Load the extension** in **one** Chrome profile: `chrome://extensions` → Developer mode → *Load unpacked* → the `Extension/` folder. It connects by itself within a few seconds.
3. **Play a video** on YouTube, Bilibili or Douyin. It goes fullscreen.
4. **Optional:** switch on what this PC has (Lossless Scaling, the extra keys, the speaker bass) in `mediactrl_settings.ini`, then reload the script (tray icon → *Reload Script*). See [Per-PC settings](#per-pc-settings).

## What it does

**Auto-fullscreen**
- When a video starts playing, the page goes fullscreen using the site's own fullscreen button, so its UI lays out as usual. A small clock shows in the top-right corner while you're in fullscreen.
- Leaving fullscreen yourself (`Esc`, `b`, clicking the video, the site's button, double-click) means "not this video": it won't re-enter until playback stops, even after switching apps or tabs and coming back. Another video still auto-enters. Reloading the page or closing the tab doesn't count as leaving.
- Clicking the video in fullscreen pauses it and then exits.
- Hover previews and thumbnails never count as "the video".

**Typing always works.** The video keys switch off while you type anywhere: page text fields (including Bilibili comments and YouTube live chat), the address bar, the find bar and dialogs.

**Even loudness (page leveler).** Each video's loudness is measured and brought to one target level: quiet videos up, loud ones down (up to ±18 dB), with a limiter for peaks. `-` / `=` set the level for all videos, and it's remembered.

**Lossless Scaling follows fullscreen** (optional). Scaling turns on when a video's fullscreen starts and off when it ends, however it ends. The scaling key only ever goes to Chrome; if Chrome isn't in front at that moment, it waits until it is. The script checks Lossless Scaling's actual state, so it never toggles the wrong way.

**Spotify silent-outro skip** (on by default). For the Spotify desktop app: if a track is still "playing" but silent in its last 10 seconds, it skips to the next one. Your own skips don't trigger it.

**Speaker bass EQ** (optional). With a Harman Kardon speaker, a bass-boost preset (Peace / Equalizer APO) is on while one of your configured games is focused, and off otherwise.

## Keys

| Key | Does | When |
|---|---|---|
| `Esc` | Leave / re-enter fullscreen | Video mode¹ |
| `b` | Pause and leave fullscreen (enter when not fullscreen) | Video mode |
| `w` `a` `s` | Up / Left / Down arrow | Video mode |
| `d`, `Right` | Tap: seek forward (the site's Right). **Hold: play at 2×** until released | Video mode |
| `e` / `q` | Skip forward / back 87 s | Video mode |
| `0` | Back to the start | Video mode |
| `1` `2` `3` `4` `5` | Speed 1× / 1.5× / 2× / 3× / 0.5× | Video mode |
| `-` / `=` | All videos quieter / louder (2 dB per press) | Video mode |
| `F1` `F2` `F3` | Toggle Lossless Scaling by hand | Video mode, if Lossless is on |
| `F6` | Status tooltip on/off | Always |
| `F7` | Video automation on/off (off also leaves fullscreen) | Always |
| `PgUp` / `PgDn`, `F14` / `F13` | Volume up / down | If `[keys] volume` is on |
| `Home` / `End` | Send F16 / F15 (e.g. Twinkle Tray brightness) | If `[keys] brightness` is on |
| `Play/Pause`, `Insert`, `Next` | Spotify play/pause, next, **previous** | If `[keys] spotify` is on |
| `Media_Prev` | **Shut the PC down immediately, no prompt** | If `[keys] shutdown` is on |

¹ *Video mode*: Chrome is in front with a video page of YouTube, Bilibili or Douyin, and you're not typing. Outside video mode these keys do what they normally do. Keys whose group is off also behave normally (PgUp scrolls, Home/End move the cursor, …).

The **F6 tooltip** shows the video (site, playing, fullscreen), whether the video keys are on, Lossless Scaling, whether the page is levelled, the speaker/bass and Spotify's time left. Problems (extension not connected, fullscreen gave up, waiting for the player) appear only when they happen.

## Per-PC settings

Everything that differs between PCs is in `mediactrl_settings.ini` next to the script. It's gitignored, so each PC keeps its own. A fresh clone starts from `mediactrl_settings.example.ini`, which lists every option with a comment. With the defaults you get the video features and the Spotify outro skip, and nothing else touches your keys.

| Section | Keys | Default |
|---|---|---|
| `[lossless]` | `enabled`, `hotkey` (Lossless Scaling's scaling hotkey) | off, `{F1}` |
| `[keys]` | `volume`, `brightness`, `spotify`, `shutdown` | all off |
| `[spotify]` | `outroSkip`, `exePath` (only if Spotify can't be found) | on, empty |
| `[speaker]` | `harmanBass`, `peacePath`, `games` (comma-separated, without `.exe`) | off, empty, empty |
| `[leveler]` | `targetDb` (set by the `-` / `=` keys) | -20 |

Switches take `1`/`0` (or `on`/`off`, `yes`/`no`); anything missing or unreadable keeps its default. Keep the file ASCII, and reload the script after editing.

**Things to know on a new PC**
- F19 is used internally as the "go fullscreen now" key, so nothing else should use it.
- Lossless Scaling needs its scaling hotkey set to `[lossless] hotkey`.
- The bass EQ expects a speaker whose name contains "Harman Kardon", and Peace presets on Ctrl+Alt+F11 (bass off) / Ctrl+Alt+F12 (bass on).

## Shared settings (`Config.ahk`)

These are the same on every PC and are kept in git.

| Setting | Purpose |
|---|---|
| `SITES` | Per site: domain, the site's fullscreen button, the player container, the fallback fullscreen key. Sent to the extension. |
| `PAGE_LEVELER` | Loudness leveler: on/off, default target, max boost/cut, averaging time, silence and limiter levels |
| `LEVEL_STEP_DB` / `LEVEL_MIN_DB` / `LEVEL_MAX_DB` | How far `-` / `=` move the level per press, and its limits |
| `SEEK_SECONDS` / `SPEEDS` | `e` / `q` jump size; the `1`–`5` speeds |
| `HOLD_SPEED` / `HOLD_TAP_MS` | Speed while `d` / Right is held; how short a press counts as a tap |
| `CLICK_EXIT_WAIT_MS` | How long `b` / a video click waits for the site's pause before exiting anyway |
| `TICK_MS` | Video evaluation timer (ms) |
| `SONG` / `SONG_EXE` | How Spotify is recognised (session name, executable) |
| `BRIDGE_PORT` | The bridge's WebSocket port (127.0.0.1 only) |

## How it works

```
┌─────────────┐  WebSocket   ┌──────────────────┐  WebSocket   ┌─────────────┐
│   Chrome    │ ───────────> │   Node bridge    │ <─────────── │   AHK v2    │
│  extension  │ <─────────── │ bridge/bridge.js │ ───────────> │   script    │
└─────────────┘  page state  └──────────────────┘   commands   └─────────────┘
                 (+ token)       127.0.0.1:9224      (+ token)     SMTC / WASAPI
```

- **AHK script:** the brain. It decides when to enter or leave fullscreen, when the video keys are on, and when to toggle Lossless Scaling, using small pure rule modules (`Lib/Decide.ahk`, `Lib/FsMachine.ahk`, `Lib/LosslessPolicy.ahk`). It also handles Spotify and all the hotkeys.
- **Chrome extension (MV3):** reports the active tab's video state (site, playing, ready, fullscreen, typing) and runs fullscreen, seek, speed and the loudness leveler inside the page.
- **Node bridge:** relays JSON between the two on `127.0.0.1` only.
  - **Access:** every client must open with the shared token, and the extension must also come from a `chrome-extension://` origin. The token is never sent back out.
  - **One extension:** only one extension copy is accepted at a time.
  - **Lifecycle:** AHK starts the bridge, and exiting or reloading closes only that process, never other `node.exe`.

**Fullscreen, step by step**
1. **Arm:** once the video plays and its player is ready, AHK arms the page and presses **F19**, which counts as a real keypress, so the page may go fullscreen.
2. **Enter:** the page clicks the site's fullscreen button. If that doesn't work, it falls back to fullscreening the player, and only then to the site's own key (`f`/`h`).
3. **Confirm:** fullscreen is confirmed by the page's own report, never assumed. Each request gets one second and one retry, then the page's last report wins.
4. **Exit:** leaving goes through the page's `exitFullscreen()`, never a toggle key, so it can't accidentally re-enter.
5. **Every synthetic key** (F19, arrows, Space, the Lossless key) is sent only while Chrome is the foreground app.

## Development

**Tests** (from the repo root, PowerShell):

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut tests\RunTests.ahk   # AHK: "N passed, M failed", exit 1 on failure
node --test bridge/ tests/js/                                                          # bridge relay + extension page logic
```

- **`tests/RunTests.ahk`** covers:
  - the pure modules: fullscreen rules, fullscreen state machine, Lossless policy, monitor geometry, settings loader;
  - end-to-end scenarios of the video code against a fake Chrome and keyboard (`VideoEnv`): auto-fullscreen, manual exits, `b`/click exits, Lossless on/off and hold-back, typing, the level keys.
- **`bridge/bridge.test.mjs`** covers the token and origin checks, relaying, the config hand-off and the one-extension rule.
- **`tests/js/pageLogic.test.js`** covers the extension's pure page helpers.
- **`docs/windows-checks.md`** records the hands-on checks on the real setup (F19, Lossless detection, per-site behaviour, …) and what was found.

**Files**

| File | Responsibility |
|---|---|
| `Main.ahk` | Entry point: startup, timers, exit |
| `Config.ahk` | Shared settings; loads the per-PC settings into `SETTINGS` |
| `State.ahk` | Shared global state |
| `StateEngine.ahk` | Program/Spotify state, and the video glue: page reports → rules → fullscreen, Lossless, video keys |
| `Video.ahk` | Video-mode key handlers, game monitor |
| `Hotkeys.ahk` | F6, F7 and the optional key groups |
| `Audio.ahk` | Spotify outro skip and playback controls |
| `Wasapi.ahk` | Audio-session loop (Spotify's peak meter) |
| `Speaker.ahk` | Speaker detection, bass EQ |
| `Bridge.ahk` | Token, `Extension/token.json`, starting/stopping the bridge |
| `BridgeClient.ahk` | AHK's WebSocket connection to the bridge |
| `UI.ahk` | F6 tooltip, fullscreen clock |
| `Lib/Decide.ahk`, `Lib/FsMachine.ahk`, `Lib/LosslessPolicy.ahk` | Pure rules: fullscreen decisions, fullscreen state machine, Lossless on/off |
| `Lib/Screen.ahk` | Pure monitor geometry |
| `Lib/Settings.ahk` | Reads the per-PC settings file over defaults |
| `Lib/LosslessDetect.ahk` | Whether Lossless Scaling is scaling (its overlay window) |
| `Lib/Media.ahk` | Windows media-session (SMTC) wrapper, used for Spotify |
| `Lib/WebSocket.ahk`, `Lib/JSON.ahk` | Vendored from [thqby/ahk2_lib](https://github.com/thqby/ahk2_lib) (MIT, `Lib/ahk2_lib-LICENSE.txt`) |
| `bridge/bridge.js` | The Node relay (`bridge/package.json`: its `ws` dependency) |
| `Extension/content.js` | In each page: finds the active video, reports its state, runs fullscreen/seek/speed/hold-to-speed and the loudness leveler, reports clicks on the video |
| `Extension/background.js` | Service worker: the bridge connection; forwards only the active tab's reports and routes commands to it |
| `Extension/lib/pageLogic.js` | Pure page helpers (site matching, typing detection, leveler maths) |
| `mediactrl_settings.example.ini` | Template for the per-PC settings file |
| `tests/`, `docs/windows-checks.md` | Tests; hands-on check results |
