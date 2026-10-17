# MediaCtrl

Windows automation for watching videos and listening to Spotify, written in **AutoHotkey v2** with a small Chrome extension.

- **Videos** on YouTube, Bilibili and Douyin go fullscreen by themselves, get keyboard controls, and all play at the same loudness.
- **Lossless Scaling** can switch on and off with video fullscreen.
- **Spotify** skips silent track endings.
- **Optional extras** per PC: volume/brightness/media keys, a bass EQ that follows a game, and keeping the speaker from going to sleep.

## Quick start

**Needs:** Windows 10/11, [AutoHotkey v2](https://www.autohotkey.com/), [Node.js](https://nodejs.org/) (with npm) and Google Chrome.

1. **Run `Main.ahk`** (as administrator if the keys should also work in admin windows). The first run sets itself up; it needs internet once.
2. **Load the extension** in **one** Chrome profile: `chrome://extensions` → *Developer mode* → *Load unpacked* → the `Extension` folder.
3. **Play a video** on YouTube, Bilibili or Douyin. It goes fullscreen.
4. **Optional:** turn on what this PC has in [`mediactrl_settings.ini`](#settings), then reload the script (tray icon → *Reload Script*).

## Features

**Auto-fullscreen.** A playing video goes fullscreen through the site's own button, so the player looks as it normally does. A small clock shows in the corner while in fullscreen.
- Leave it yourself (`Esc`, `b`, a click on the video, the site's button) and that video stays out until playback stops, even if you switch apps or tabs and come back. Other videos still go fullscreen.
- A click on the video pauses it, then leaves fullscreen.
- Reloading the page or closing the tab never blocks the next video.

**Typing always works.** The video keys turn off while you type anywhere: page text boxes (Bilibili comments and YouTube live chat included), the address bar, the find bar and dialogs.

**Same loudness for every video.** Each video's loudness is measured the way ears hear it and brought to one level: quiet videos up, loud ones down. Loud moments are turned down within a fraction of a second; a new video starts quiet and settles within about half a second; a video you scroll back to (or that loops) keeps the level it had. `-` / `=` set that level, and it's remembered.

**Lossless Scaling** *(optional)*. Scaling turns on when a video's fullscreen starts and off when it ends, however it ends. It's toggled only while Chrome is in front (otherwise it waits), and only when its real state differs, so it never toggles the wrong way.

**Spotify** *(desktop app)*. If a track is still playing but silent in its last 10 seconds, it skips to the next one.

**Speaker bass** *(optional)*. With a Harman Kardon speaker, a bass-boost preset (Peace / Equalizer APO) is on while one of your games is focused.

**Speaker keep-awake** *(optional)*. Speakers like the SoundSticks 4 go to standby after about 10 minutes of silence and cut off the start of the next sound. This plays a short tone every few minutes while nothing else is playing: 19 kHz by default, above what most adults hear.

## Keys

| Key | Does | Active |
|---|---|---|
| `Esc` | Leave / re-enter fullscreen | Video mode¹ |
| `b` | Pause and leave fullscreen (or enter it) | Video mode |
| `w` `a` `s` | Up / Left / Down arrow | Video mode |
| `d` or `Right` | Tap: seek forward. **Hold: play at 2×** until released | Video mode |
| `e` / `q` | Forward / back 87 s | Video mode |
| `0` | Back to the start | Video mode |
| `1` `2` `3` `4` `5` | Speed 1× / 1.5× / 2× / 3× / 0.5× | Video mode |
| `-` / `=` | All videos quieter / louder | Video mode |
| `F1` `F2` `F3` | Toggle Lossless Scaling by hand | Video mode, with Lossless on |
| `F6` | Status tooltip | Always |
| `F7` | Pause / resume all video automation | Always |
| `PgUp` `PgDn`, `F14` `F13` | Volume up / down | `[keys] volume` |
| `Home` / `End` | Send F16 / F15 (e.g. for Twinkle Tray brightness) | `[keys] brightness` |
| `Play/Pause`, `Insert`, `Next` | Spotify play/pause, next track, **previous** track | `[keys] spotify` |
| `Media_Prev` | **Shut down the PC at once, no prompt** | `[keys] shutdown` |

¹ **Video mode:** Chrome is in front showing a YouTube, Bilibili or Douyin video, and you aren't typing. Otherwise these keys work as usual, and so do keys whose group is switched off.

The **F6 tooltip** shows the video, whether the video keys are on, Lossless Scaling, the loudness leveler, the speaker and Spotify's time left. Problems appear only when there are any.

## Settings

Each PC has its own `mediactrl_settings.ini` next to the script. It isn't in git, and the first run creates it from `mediactrl_settings.example.ini`, which explains every option. Out of the box you get the video features and the Spotify skip; nothing else touches your keys.

| Section | Options | Default |
|---|---|---|
| `[lossless]` | `enabled`; `hotkey`: Lossless Scaling's scaling hotkey | off; `{F1}` |
| `[keys]` | `volume`, `brightness`, `spotify`, `shutdown` | all off |
| `[spotify]` | `outroSkip`; `exePath`: only if Spotify isn't found | on; empty |
| `[speaker]` | `harmanBass`; `peacePath`; `games`: comma-separated, no `.exe` | off; empty; empty |
| | `keepAwake`; `keepAwakeMinutes`; `keepAwakeHz`; `keepAwakeDb` | off; 5; 19000; -20 |
| `[leveler]` | `targetDb`: the loudness level, set by `-` / `=` | -20 |

Switches take `1` / `0` (or `on`/`off`, `yes`/`no`). Anything missing or mistyped keeps its default. Reload the script after editing.

Shared fine-tuning (seek length, speeds, how the leveler behaves, per-site player details) is in `Config.ahk`, commented in place.

**Good to know**
- F19 is used internally to trigger fullscreen, so nothing else should use it.
- The bass EQ expects a speaker named "Harman Kardon", with Peace presets on Ctrl+Alt+F11 (off) and Ctrl+Alt+F12 (on).

## How it works

```
┌─────────────┐  WebSocket   ┌──────────────────┐  WebSocket   ┌─────────────┐
│   Chrome    │ ───────────> │   Node bridge    │ <─────────── │   AHK v2    │
│  extension  │ <─────────── │ bridge/bridge.js │ ───────────> │   script    │
└─────────────┘  page state  └──────────────────┘   commands   └─────────────┘
                                 127.0.0.1 only
```

- **The extension** reports what the active tab's video is doing (playing, ready, fullscreen, typing) and carries out fullscreen, seek, speed and the loudness leveler inside the page.
- **The AHK script** decides what should happen and sends the commands. Its decisions come from small, tested rule modules in `Lib/`, and every key it presses goes only to Chrome.
- **The bridge** passes messages between them on this PC only.
  - **Access:** both sides must present a shared secret that the script generates, and only one copy of the extension is accepted at a time.
  - **Lifecycle:** the script starts the bridge, and closes only that process on exit.
- **Fullscreen is never guessed.** The script asks the page to go fullscreen and waits for the page to confirm. If no confirmation arrives, it retries once, then trusts what the page last reported. Leaving fullscreen goes through the page too, never a toggle key.

## Development

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut tests\RunTests.ahk   # AHK tests
node --test bridge/ tests/js/                                                          # bridge + extension tests
```

- **AHK tests:** cover the rule modules and the settings loader, plus end-to-end scenarios of the video code against a fake Chrome and keyboard.
- **Node tests:** cover the bridge's access checks and relaying, and the extension's page helpers.
- **`docs/windows-checks.md`:** records the hands-on checks on the real setup and what they found.

| Path | What's there |
|---|---|
| `Main.ahk` | Entry point |
| `Config.ahk`, `State.ahk` | Shared settings; runtime state |
| `StateEngine.ahk`, `Video.ahk` | Video automation and the video keys |
| `Hotkeys.ahk`, `UI.ahk` | F6/F7 and the optional key groups; tooltip and clock |
| `Audio.ahk`, `Wasapi.ahk`, `Speaker.ahk` | Spotify, audio sessions, speaker bass |
| `Bridge.ahk`, `BridgeClient.ahk`, `bridge/` | The bridge and the script's connection to it |
| `Lib/` | Rule modules, settings loader, helpers, vendored [ahk2_lib](https://github.com/thqby/ahk2_lib) (MIT) |
| `Extension/` | The Chrome extension |
| `tests/`, `docs/` | Tests; check results |
