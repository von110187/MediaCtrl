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
