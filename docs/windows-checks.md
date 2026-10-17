# Windows checks

Results of the stop-and-check steps in the Windows port plan.

## 1. F19 activation (Task 1) — 2026-10-17: PASS

A page with a `keydown` listener calling `requestFullscreen()` on `F19`, served
from `http://localhost:8765`, focused in Chrome. A one-off AHK v2 script sent
`{F19}`. The page went fullscreen and its title read `OK trusted=true`.

An OS-level F19 from AHK counts as user activation in Windows Chrome, so the
F19 nudge stays the normal way into fullscreen; the `fsKey` fallback is only
the retry.

## 2. Lossless Scaling state detection (Task 1) — 2026-10-17: DETECTABLE

Top-level windows (hidden ones included) were listed before, during and after
scaling a Chrome window with `CONFIG.LOSSLESS_HOTKEY`.

Only while scaling is on, `LosslessScaling.exe` owns two extra **visible**
windows covering the whole screen (5120x2160):

| Class | Style / ExStyle |
|---|---|
| `LosslessScaling` | `0x9c000000` / `0x80800a8` |
| `LosslessScalingBlk` | `0x9c000000` / `0x8000080` |

Both were gone after scaling was turned off again. The app's own windows
(`HwndWrapper[LosslessScaling;;…]`) exist either way and are hidden.

`Lib/LosslessDetect.ahk` provides `_LosslessActive()`: a visible window of
class `LosslessScaling` from `LosslessScaling.exe`. `LosslessPolicy.SetDetected`
is fed from it before each change.

## 3. WebSocket.ahk callbacks vs hotkeys (Task 5) — 2026-10-17: NON-BLOCKING

thqby `WebSocket.ahk` in async mode, against `bridge/bridge.js`:

- Round trip: `hello` → `extConnected`, then `ping` → `pong` in 15 ms.
- Bridge restart: the client only notices when a send fails (WinHTTP doesn't
  report the aborted read), so it pings every 1 s; it was reconnected 2.8 s
  after the bridge was killed and restarted.
- Stall test: `OnBridgeMessage` busy-looped 300 ms on every `pong`, with
  pongs about 3 times a second (~90 % busy) for 20 s, while the user tapped
  PgUp/PgDn (handled by the test script). 96 presses: key-down to handler
  start averaged 17 ms, worst 219 ms, none over 300 ms; a 10 ms timer never
  went more than 47 ms between runs. The user saw the volume follow the keys.

The busy handler is interrupted by hotkeys and timers, so messages are
dispatched to `OnBridgeMessage` directly; no `SetTimer` wrap is needed.

## 4. Ported extension reports and selectors (Task 6) — 2026-10-17: PASS

The new unpacked `Extension/` in one Chrome profile, the old extension and
old MediaCtrl removed, `bridge/bridge.js` on 9224, and a listening AHK client
that sent the planned `SITES` as `config` and a `probe` every 5 s.

| Site | `state` while playing | `probeResult.hits` |
|---|---|---|
| YouTube `/watch` | `playable=1 playing=1 ready=1` | `fsButton` ✓ `playerSelector` ✓ (2 videos) |
| Bilibili `/video/` | `playable=1 playing=1 ready=1` | `fsButton` ✓ `playerSelector` ✓ (1 video) |
| Douyin feed | `playable=1 playing=1 ready=1` | `fsButton` ✓ (no `playerSelector` configured; 3 videos) |

Also seen: the YouTube home and channel pages report `playable=0`; leaving a
tab for the next reports `editableFocused=1` (the page lost focus) and then
the new tab's state; `chrome://extensions` reports the "nothing here" state.

## 5. Page-tracked fullscreen, Lossless and video keys (Task 7) — 2026-10-17: PASS

The new `Main.ahk` (run as before), the new extension in one profile.

| Check | Result |
|---|---|
| YouTube: play → fullscreen, no stray `f`, Lossless on; Esc → out, Lossless off, stays out while playing | ✓ |
| Alt+Tab away and back → still out; pause, then play → re-enters | ✓ |
| Double-click exit → stays out; F5 → reload, re-enters when the video plays | ✓ |
| `wasd` typed into the YouTube search box and the address bar (Ctrl+L) | ✓ letters appear |
| Single click on the video in fullscreen → pauses, then exits | ✓ |
| Bilibili: hold `d` seeks; `wasd` in the comment box | ✓ |
| Douyin: fullscreen shows danmaku; scrolling the feed → no false exits | ✓ |
| AHK reload mid-fullscreen → no Lossless flip, keys back within ~3 s | ✓ |
| Ctrl+W on a fullscreen tab → Lossless off, next video not blocked (design check 4) | ✓ |

**Design check 4 (Ctrl+W):** closing the tab makes Chrome activate another
tab, the extension reports it (new `pageId`, not fullscreen), and that counts
as a page change, not a manual exit. The `tabs.onRemoved` fallback the design
describes isn't needed.

**Lossless manual presses — changed after trying it.** The design's rule (a
manual F1/F2/F3 during a fullscreen video hands that video to the user, so it
stays off until pressed again) wasn't wanted: "when lossless scaling is off,
no need to keep it as off until i manually press it back, i think normal
behaviour is good enough". Now scaling follows fullscreen every time (also
when the same video re-enters), and a manual press only flips the tracked
state. Re-checked: F1 off → Esc (stays off) → Esc re-enters with Lossless on ✓.
Review Focus 5 no longer applies.

## 6. Shared WASAPI loop and the leveler on page state (Task 8) — 2026-10-17: PASS

- Old and new `_GetSongPeak` / `_GetBrowserPeak` / `_SetBrowserVolume` /
  `_GetWasapiSessionsDebug` run side by side on the live sessions gave the
  same session list and counts (`total=4 browserSessions=1 volumeSet=1`);
  only the live peak values differed.
- F6: Spotify peak above 0 while playing, 0 when paused ✓.
- Douyin: the leveler multiplier dropped on a loud video and went back to
  1.0x on a non-video page ✓.
- Spotify outro skip fired on a silent outro after the reload ✓.

## 7. F6 tooltip (Task 9) — 2026-10-17: PASS

The VIDEO lines (connected, URL, site, playable/playing/ready, typing,
fullscreen + manual exit, video keys, gave up, Lossless on/pending/detected)
and the last 15 bridge messages show and update; PgUp/PgDn stay responsive
with the tooltip on.

## 8. Harman Kardon bass (Task 10) — 2026-10-17: PASS

The default output reports as `Harman Kardon (High Definition Audio Device)`,
so the old exact-match check never matched. With `_IsHarmanSpeaker()`:
focusing Zenless Zone Zero → `Bass: ON`; Alt+Tab away → `Bass: OFF`.

## 9. Hold d / Right for 2× (follow-up) — 2026-10-17: PASS

Replaces Bilibili/Douyin-only "hold d = hold Right". On YouTube, Bilibili and
Douyin: a tap of `d` or Right seeks as before; holding either plays at 2×
(set by the extension) and returns to the previous speed on release ✓.

## 10. Page leveler, hold safety net, monitor-aware Lossless and clock — 2026-10-17

- **Page leveler:** a first version (a Web Audio compressor) attached on all
  three sites but didn't even out loudness between videos — "same as the
  volume I set". Replaced with AGC (measure each video's loudness, move its
  gain toward one target, limiter after). Re-checked on Douyin, Bilibili and
  YouTube: "Even now, sounds good" ✓. F6 shows `Page leveler: on`, and the
  WASAPI leveler stands down on those pages (its Smoothed/Multiplier stay idle).
- **2× hold safety net:** holding `d` ~4 s stays at 2× throughout (AHK's
  keep-alive arrives), and returns to normal on release ✓. The expiry path
  (keep-alive stops → normal after 1.5 s) wasn't forced live.
- **Lossless detection on Chrome's monitor:** `detected: yes` while scaling,
  `no` after Esc ✓. Single 5120x2160 monitor here, so the per-monitor part
  only matters with a second screen.
- **Clock on Chrome's monitor:** still in its usual spot ✓.
- **On-screen speed label:** built and shown working, then removed at the
  user's request ("quite useless").

## 11. Leveler keys, fallback leveler removed, glue refactor — 2026-10-17: PASS

- `-` / `=` in video mode: tooltip shows the level, all video sound follows
  within about a second, Spotify unaffected, and the level survives an AHK
  reload ✓.
- After routing the video glue through `VideoEnv` (for the new glue tests)
  and removing the WASAPI fallback leveler: YouTube auto-fullscreen with
  Lossless on, Esc exits with Lossless off, w/a/s/d, e/q and 1–5 unchanged ✓.
  Chrome's per-app volume in the Windows mixer was confirmed at 100 % before
  the old leveler was removed.

## 12. Per-PC settings and the YouTube re-entry fix — 2026-10-17: PASS

- **This PC** with `mediactrl_settings.ini` switching everything on: Lossless
  on/off with fullscreen and by F1, PgUp/PgDn volume, Home/End brightness,
  Play/Pause and Insert to Spotify, `=` level tooltip remembered across a
  reload — all as before ✓.
- **Fresh clone** of the branch (scratch folder, no settings file): the
  template was copied on first start; Lossless and every `[keys]` group off,
  outro skip on, level -20; `Main.ahk` loads; 67/67 AHK tests pass. Not run
  live there (it would have killed this PC's bridge), so the keys passing
  through with the groups off rests on AHK's `#HotIf`.
- **YouTube: Esc out, one Esc tap back in, sometimes exited at once.** Traced
  with temporary logging: when YouTube's fullscreen button took longer than
  the 300 ms cutoff (once 289 ms in the trace), the extension's
  `requestFullscreen()` fallback was refused ("Permissions check failed" — the
  button's request had used the activation), so it reported `enterFailed`,
  AHK sent the `f` key, YouTube finished entering from the button, then `f`
  toggled it back out. Forcing the overlap (cutoff 5 ms) reproduced it on
  most tries. Fix: after a refused fallback, wait up to 500 ms more for the
  button's own fullscreen before reporting `enterFailed`. With the forced
  overlap: 24/24 re-entries settled, no `f` sent, no exits. With the normal
  cutoff: re-entry stays in ✓.

## 13. Speaker keep-awake (SoundSticks 4) — 2026-10-17: PASS

The SoundSticks 4 (3.5 mm) goes to standby after a stretch of silence — about
10 minutes per a community answer; Harman documents no setting for it.
`[speaker] keepAwake` plays a 2 s tone every 5 min while every audio session
reads silent.
- 20 Hz at -30 dB: inaudible, but the speaker still went to sleep after 15+
  min of silence (Windows volume 50 %; low tones also get filtered on the way).
  The silence check itself was confirmed working (all sessions at 0).
- Candidates, all inaudible to the user: 20 Hz at -18 / -12 dB, 30 Hz at
  -18 dB, 19 kHz at -20 dB.
- 19 kHz at -20 dB: after 15+ min of silence, sound started instantly ✓.
  Now the default.
- `SoundPlay` failed on a long file path (MCI); keep-awake uses `PlaySound`.
