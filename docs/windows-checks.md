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
