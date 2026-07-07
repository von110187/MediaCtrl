; ============ MONITOR AUDIO ============
; Called every tick. Spotify outro logic only — no playback state tracking here.

MonitorAudio(sessions) {
    global CONFIG
    for session in sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG)
            _CheckSongOutro(session)
    }
}

; ============ SONG OUTRO SKIP ============
; Skips to next track when status is 4 (playing) but audio peak is 0 —
; catches silent Spotify outros that don't change playback status.
;
; Track changes from any source (hotkey, mouse, phone) are detected by
; LastUpdatedTime jumping forward, which arms a cooldown so the post-skip
; silence isn't misread as a silent outro.
;
; LastUpdatedTime is Windows FILETIME ÷ 10,000,000 (epoch Jan 1 1601).
; Subtract 11644473600 to convert to Unix epoch.

_CheckSongOutro(session) {
    global State
    try {
        session.UpdateTimelineProperties()
        reportedPos := session.Position
        lastUpdated := session.LastUpdatedTime
        duration    := session.EndTime
        status      := session.PlaybackStatus

        ; ── Track-change detection (universal) ─────────────────────────────
        ; LastUpdatedTime resets on any new track, regardless of trigger
        ; (hotkey, mouse, phone). A forward jump means a new track loaded.
        if State.songLastUpdatedTime != 0 && lastUpdated > State.songLastUpdatedTime {
            State.songSkipCooldownUntil := A_TickCount + 2000
            State.songSkipLock          := false
        }
        State.songLastUpdatedTime := lastUpdated

        if status != 4
            return

        currentFiletime := 0
        DllCall("GetSystemTimeAsFileTime", "int64*", &currentFiletime)
        unixNow         := (currentFiletime - 116444736000000000) // 10000000
        lastUpdatedUnix := lastUpdated - 11644473600  ; Windows epoch → Unix epoch
        elapsed         := unixNow - lastUpdatedUnix
        if elapsed < 0 || elapsed > 600
            return
        pos := reportedPos + elapsed

        ; ── Silent-outro detection ──────────────────────────────────────────
        ; Spotify stays at status=4 through silent outros — only peak drops to 0.
        ; Cooldown suppresses this for 2s after a track change; duration check
        ; only fires in the last 10s of the track.
        peak := _GetSongPeak()
        if peak >= 0 {
            if (peak < 0.001) {
                inOutroWindow := (duration > 0) && ((duration - pos) <= 10)
                if !State.songSkipLock && A_TickCount >= State.songSkipCooldownUntil && inOutroWindow {
                    State.songSkipLock := true
                    session.SkipNext()
                }
            } else {
                State.songSkipLock := false
            }
        }
    } catch {
    }
}

; ============ WASAPI PEAK METER ============
; Returns Spotify's current audio peak (0.0–1.0), or -1 on failure.
; Spotify runs as an Edge PWA with no dedicated exe and no WASAPI display
; name, so it can't be matched directly — instead this finds all msedge.exe
; sessions and returns the highest peak among them. Exact if Spotify is the
; only audio source in Edge; still a valid "is Edge silent?" signal otherwise.
_GetSongPeak() {
    global WASAPI_CLSIDS

    try {
        enumerator := ComObject(WASAPI_CLSIDS.MMDeviceEnumerator, WASAPI_CLSIDS.IMMDeviceEnumerator)
        ComCall(4, enumerator, "int", 0, "int", 1, "ptr*", &devicePtr := 0)

        sessionManagerGUID := Buffer(16)
        DllCall("Ole32\CLSIDFromString", "Str", WASAPI_CLSIDS.IAudioSessionManager2, "Ptr", sessionManagerGUID)
        ComCall(3, devicePtr, "ptr", sessionManagerGUID, "int", 23, "ptr", 0, "ptr*", &sessionManagerPtr := 0)
        ComCall(5, sessionManagerPtr, "ptr*", &sessionEnumPtr := 0)
        ComCall(3, sessionEnumPtr, "int*", &count := 0)

        maxPeak := -1
        Loop count {
            ComCall(4, sessionEnumPtr, "int", A_Index - 1, "ptr*", &sessionControlPtr := 0)
            try {
                sessionControl2 := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.IAudioSessionControl2)
                if !sessionControl2
                    continue

                ComCall(14, sessionControl2, "uint*", &pid := 0)
                sessionControl2 := ""

                if pid <= 0
                    continue

                try procName := ProcessGetName(pid)
                catch
                    continue

                if !InStr(procName, "Spotify")
                    continue

                meterInfo := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.IAudioMeterInformation)
                if !meterInfo
                    continue

                ComCall(3, meterInfo, "float*", &peak := 0.0)
                meterInfo := ""

                if peak > maxPeak
                    maxPeak := peak
            } finally {
                ObjRelease(sessionControlPtr)
            }
        }

        ObjRelease(sessionEnumPtr)
        ObjRelease(sessionManagerPtr)
        ObjRelease(devicePtr)
        return maxPeak
    } catch {
    }
    return -1
}


; ============ WASAPI SESSION DEBUG ============
; Returns all WASAPI session display names + identifiers as a string.
; Used by the tooltip to diagnose which session name Spotify registers under.

_GetWasapiSessionsDebug() {
    global WASAPI_CLSIDS
    result := ""
    try {
        enumerator := ComObject(WASAPI_CLSIDS.MMDeviceEnumerator, WASAPI_CLSIDS.IMMDeviceEnumerator)
        ComCall(4, enumerator, "int", 0, "int", 1, "ptr*", &devicePtr := 0)

        sessionManagerGUID := Buffer(16)
        DllCall("Ole32\CLSIDFromString", "Str", WASAPI_CLSIDS.IAudioSessionManager2, "Ptr", sessionManagerGUID)
        ComCall(3, devicePtr, "ptr", sessionManagerGUID, "int", 23, "ptr", 0, "ptr*", &sessionManagerPtr := 0)
        ComCall(5, sessionManagerPtr, "ptr*", &sessionEnumPtr := 0)
        ComCall(3, sessionEnumPtr, "int*", &count := 0)

        Loop count {
            ComCall(4, sessionEnumPtr, "int", A_Index - 1, "ptr*", &sessionControlPtr := 0)
            try {
                sessionControl2 := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.IAudioSessionControl2)
                if !sessionControl2
                    continue
                ComCall(4,  sessionControlPtr, "ptr*", &namePtr := 0)
                ComCall(12, sessionControl2,   "ptr*", &idPtr   := 0)
                ComCall(14, sessionControl2,   "uint*", &pid    := 0)
                sessionControl2 := ""
                name := namePtr ? StrGet(namePtr, "UTF-16") : "(no name)"
                id   := idPtr   ? StrGet(idPtr,   "UTF-16") : "(no id)"
                procName := ""
                try procName := ProcessGetName(pid)
                result .= "  [" pid " " procName "] " name "`n    " SubStr(id, 1, 60) "`n"
            } finally {
                ObjRelease(sessionControlPtr)
            }
        }
        ObjRelease(sessionEnumPtr)
        ObjRelease(sessionManagerPtr)
        ObjRelease(devicePtr)
    } catch as e {
        result := "  error: " e.Message
    }
    return result
}
; ============ SONG CONTROLS ============

_SongTogglePlayPause() {
    global State, CONFIG
    for session in State.sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG) {
            session.TogglePlayPause()
            return
        }
    }
    ; No session yet — Spotify PWA is open but hasn't played anything (no SMTC session exists).
    _ActivateSpotifyPWA("{Space}")
}

_SongSkipNext() {
    global State, CONFIG
    for session in State.sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG) {
            session.SkipNext()
            return
        }
    }
    ; No session — activate Spotify PWA and send Ctrl+Right
    _ActivateSpotifyPWA("^{Right}")
}

_SongSkipPrevious() {
    global State, CONFIG
    for session in State.sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG) {
            session.SkipPrevious()
            ; If not playing, also fire Play() so track starts immediately
            if session.PlaybackStatus != 4
                session.Play()
            return
        }
    }
    ; No session — activate Spotify PWA and send Ctrl+Left then Space
    _ActivateSpotifyPWA("^{Left}", "{Space}")
}

; Activates the Spotify PWA window, sends a key (and optional second key after a delay), then restores focus.
_ActivateSpotifyPWA(key, key2 := "", delay := 2500) {
    if WinExist("Spotify - Web Player ahk_class Chrome_WidgetWin_1") {
        prevWin := WinExist("A")
        WinActivate("Spotify - Web Player ahk_class Chrome_WidgetWin_1")
        WinWaitActive("Spotify - Web Player ahk_class Chrome_WidgetWin_1", , 1)
        Send(key)
        if key2 != "" {
            Sleep(delay)
            Send(key2)
        }
        Sleep(100)
        if prevWin
            WinActivate("ahk_id " . prevWin)
    }
}
