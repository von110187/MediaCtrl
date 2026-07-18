; ============ MEDIA EVENT REGISTRATION ============
; OS-level playback events — faster than polling for browser state changes.

RegisterMediaEvents() {
    try {
        for session in Media.GetSessions()
            _RegisterSessionEvents(session)
    } catch {
    }
    Media.AddSessionsChangedEvent(_OnSessionsChanged)
}

_RegisterSessionEvents(session) {
    session.AddPlaybackInfoChangedEvent(_OnPlaybackInfoChanged)
}

_OnPlaybackInfoChanged(session, *) {
    global State, CONFIG
    try {
        if !InStr(session.SourceAppUserModelId, CONFIG.BROWSER)
            return
        newIsPlaying := session.PlaybackStatus = 4
        if State.browserIsPlaying != newIsPlaying {
            ; event-driven, no debounce needed
            State.browserIsPlaying       := newIsPlaying
            State.browserNotPlayingTicks := 0
            try {
                freshSessions := Media.GetSessions()
                State.sessions := freshSessions
            } catch {
            }
            _EvalVideoHotkeys()
        }
    } catch {
    }
}

_OnSessionsChanged(*) {
    try {
        sessions := Media.GetSessions()
        for session in sessions
            _RegisterSessionEvents(session)
        UpdateState(sessions)
    } catch {
    }
}

; ============ MONITOR GAME ============

MonitorGame() {
    global State, CONFIG

    for game in CONFIG.GAME_LIST {
        exeName    := game . ".exe"
        isRunning  := ProcessExist(exeName) ? true : false
        wasRunning := State.gameRunning.Has(game) ? State.gameRunning[game] : false

        if isRunning = wasRunning
            continue

        State.gameRunning[game] := isRunning

        ; Update bass on game open/close
        if (State.activeSpeaker = "Harman Kardon")
            _UpdateHarmanBass()
    }
}

; ============ MONITOR LM STUDIO ============
; Kills LosslessScaling when LM Studio is running (GPU conflict).

MonitorLMStudio() {
    if ProcessExist("LM Studio.exe") {
        if ProcessExist("LosslessScaling.exe")
            ProcessClose("LosslessScaling.exe")
        return
    }
    if !ProcessExist("LosslessScaling.exe") {
        Run('"D:\Program Files (x86)\Steam\steamapps\common\Lossless Scaling\LosslessScaling.exe"')
        WinWait("ahk_exe LosslessScaling.exe")
        WinClose("ahk_exe LosslessScaling.exe")
    }
}

; ============ VIDEO HOTKEYS — dynamic registration ============
; All video keys default OFF. _SetVideoHotkeys() in StateEngine toggles them.

InitVideoHotkeys() {
    ; b — exit fullscreen + pause
    Hotkey("$b", _HK_b, "Off")

    ; WASD — navigation (send arrow keys on media sites)
    Hotkey("$w", _HK_w, "Off")
    Hotkey("$a", _HK_a, "Off")
    Hotkey("$s", _HK_s, "Off")
    Hotkey("$d", _HK_d, "Off")

    ; 0 — restart from beginning; 1234 — playback speed
    Hotkey("$0", _HK_0, "Off")
    Hotkey("$1", _HK_1, "Off")
    Hotkey("$2", _HK_2, "Off")
    Hotkey("$3", _HK_3, "Off")
    Hotkey("$4", _HK_4, "Off")

    ; Esc — toggle fullscreen
    Hotkey("$Esc", _HK_Esc, "Off")

    ; F1 F2 F3 — lossless hotkeys
    Hotkey("$F1", _HK_Lossless, "Off")
    Hotkey("$F2", _HK_Lossless, "Off")
    Hotkey("$F3", _HK_Lossless, "Off")

    ; F5 — exit fullscreen + lossless + refresh
    Hotkey("$F5", _HK_F5, "Off")
}

; ── Video hotkey handlers ─────────────────────────────────────────────────────

_HK_b(*) {
    global State
    if State.browserInFullScreen {
        if State.browserIsPlaying {
            Send(" ")
            State.pendingExitFS := true
        } else {
            _ExitFullscreenByUser()
        }
    }
}

_HK_w(*) => Send("{Up}")
_HK_a(*) => Send("{Left}")
_HK_s(*) => Send("{Down}")

_HK_d(*) {
    global State
    site := State.matchedSite
    if site && site.holdSeek {
        Send("{Right down}")
        KeyWait("d")
        Send("{Right up}")
    } else {
        Send("{Right}")
    }
}

_HK_0(*) => SendCommand("seek_0")
_HK_1(*) => SendCommand("speed_1.0")
_HK_2(*) => SendCommand("speed_1.5")
_HK_3(*) => SendCommand("speed_2.0")
_HK_4(*) => SendCommand("speed_3.0")

_HK_Esc(*) {
    global State
    if State.browserInFullScreen
        _ExitFullscreenByUser()
    else
        _EnterFullscreen()
}

_HK_Lossless(*) {
    global CONFIG
    Send(CONFIG.LOSSLESS_HOTKEY)
}

_HK_F5(*) {
    global State, CONFIG
    site := State.matchedSite
    if !site || !State.browserInFullScreen
        return

    if site.mouseCenter
        MouseMove(A_ScreenWidth/2, A_ScreenHeight/2)

    Send(CONFIG.LOSSLESS_HOTKEY)
    Send(site.fsKey)
    State.browserInFullScreen := false

    ; blocks auto re-entry during reload; _UpdateMediaState clears manuallyExitedFS once audio stops
    State.pendingF5       := true
    State.manuallyExitedFS := true

    Send("{F5}")
}
