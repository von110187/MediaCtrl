; ============ LOSSLESS SCALING DETECTION ============
; While scaling is active, Lossless Scaling shows a full-screen overlay window
; of class "LosslessScaling" (plus a "LosslessScalingBlk" one); neither exists
; while it's off. Checked on Windows 2026-10-17 — see docs/windows-checks.md.

_LosslessActive() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(false)
    try return WinExist("ahk_class LosslessScaling ahk_exe LosslessScaling.exe") != 0
    finally DetectHiddenWindows(prev)
}
