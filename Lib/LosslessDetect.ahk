; ============ LOSSLESS SCALING DETECTION ============
; While scaling is active, Lossless Scaling shows a full-screen overlay window
; of class "LosslessScaling" (plus a "LosslessScalingBlk" one); neither exists
; while it's off. Checked on Windows 2026-10-17 — see docs/windows-checks.md.
; The overlay covers the monitor of the window being scaled, so with `mon`
; ({l, t, r, b}) only an overlay over that monitor counts — scaling a game on
; another screen isn't "on" for Chrome.

_LosslessActive(mon := "") {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(false)
    try {
        for hwnd in WinGetList("ahk_class LosslessScaling ahk_exe LosslessScaling.exe") {
            if !IsObject(mon)
                return true
            WinGetPos(&x, &y, &w, &h, hwnd)
            if Screen.Covers({x: x, y: y, w: w, h: h}, mon)
                return true
        }
        return false
    } finally {
        DetectHiddenWindows(prev)
    }
}
