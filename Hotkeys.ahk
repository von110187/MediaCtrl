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
; Each group is registered at startup only if mediactrl_settings.ini [keys]
; says so; otherwise the keys do what Windows normally does (PgUp scrolls,
; Home/End move, ...). Not #HotIf: a #HotIf condition is checked by the
; script's main thread on every press, and while that thread was busy (e.g.
; reading Spotify's media session) the key slipped through as a plain PgUp.
InitPersonalKeys() {
    if SETTINGS.keys.volume {
        Hotkey("*F13",  (*) => Send("{Blind}{Volume_Down}"))
        Hotkey("*F14",  (*) => Send("{Blind}{Volume_Up}"))
        Hotkey("*PgDn", (*) => Send("{Blind}{Volume_Down}"))
        Hotkey("*PgUp", (*) => Send("{Blind}{Volume_Up}"))
    }
    if SETTINGS.keys.brightness {  ; Twinkle Tray, its hotkeys set to F15 / F16
        Hotkey("End",  (*) => Send("{F15}"))
        Hotkey("Home", (*) => Send("{F16}"))
    }
    if SETTINGS.keys.spotify {
        Hotkey("$Media_Play_Pause", (*) => _SongTogglePlayPause())
        Hotkey("$Media_Next",       (*) => _SongSkipPrevious())  ; next button → skip previous
        Hotkey("$Insert",           (*) => _SongSkipNext())
    }
    if SETTINGS.keys.shutdown  ; immediate shutdown, no prompt
        Hotkey("$Media_Prev", (*) => Run("shutdown.exe /s /f /t 0"))
}
