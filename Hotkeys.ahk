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

; ── Personal key groups ──────────────────────────────────────────────────────
; Each group is on only if mediactrl_settings.ini [keys] says so; otherwise the
; keys do what Windows normally does (PgUp scrolls, Home/End move, ...).

; Volume
#HotIf SETTINGS.keys.volume
F13::  Volume_Down
F14::  Volume_Up
PgDn:: Volume_Down
PgUp:: Volume_Up

; Brightness via Twinkle Tray (its hotkeys set to F15 / F16)
#HotIf SETTINGS.keys.brightness
End::  Send("{F15}")
Home:: Send("{F16}")

; Spotify media keys
#HotIf SETTINGS.keys.spotify
$Media_Play_Pause:: _SongTogglePlayPause()
$Media_Next::       _SongSkipPrevious()   ; next button → skip previous
$Insert::           _SongSkipNext()

; Immediate shutdown, no prompt
#HotIf SETTINGS.keys.shutdown
$Media_Prev::       Run("shutdown.exe /s /f /t 0")

#HotIf
