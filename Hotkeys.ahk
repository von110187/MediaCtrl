; ============ HOTKEYS ============

; ── F6: Toggle tooltip ────────────────────────────────────────────────────────
F6:: {
    global State
    State.showTooltip := !State.showTooltip
    if !State.showTooltip
        ToolTip()
}

; ── F7: Toggle video monitoring ──────────────────────────────────────────────
; Off exits fullscreen (if in it) and turns the video keys off.
F7:: {
    global State
    VideoSetMonitor(!State.monitorVideo)
    if !State.showTooltip {
        ToolTip(State.monitorVideo ? "Monitor: On" : "Monitor: Off")
        SetTimer(() => ToolTip(), -1000)
    }
}

; ── Volume ────────────────────────────────────────────────────────────────────
F13::  Volume_Down
F14::  Volume_Up
PgDn:: Volume_Down
PgUp:: Volume_Up

; ── Brightness via Twinkle Tray ──────────────────────────────────────────────
End::  Send("{F15}")
Home:: Send("{F16}")

; ── Media keys ───────────────────────────────────────────────────────────────
$Media_Play_Pause:: _SongTogglePlayPause()
$Media_Next::       _SongSkipPrevious()   ; next button → skip previous
$Media_Prev::       Run("shutdown.exe /s /f /t 0")
$Insert::           _SongSkipNext()
