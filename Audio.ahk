; ============ MONITOR AUDIO ============
; Called every tick. song outro logic only — no playback state tracking here.

MonitorAudio(sessions) {
    global CONFIG
    for session in sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG)
            _CheckSongOutro(session)
    }
}

; ============ SONG OUTRO SKIP ============
; Skips to next track when status is 4 (playing) but audio peak is 0 —
; catches silent outros where Spotify never changes status.
;
; Track changes (from any source — keyboard, mouse, phone) are detected by
; LastUpdatedTime jumping forward. When that happens the cooldown is set so
; the transient post-skip silence doesn't get misread as a silent outro.
;
; LastUpdatedTime from the Media library is Windows FILETIME ÷ 10000000 (Windows epoch seconds, Jan 1 1601).
; Subtract 11644473600 to convert to Unix epoch before comparing with unixNow.

_CheckSongOutro(session) {
    global State
    try {
        session.UpdateTimelineProperties()
        reportedPos := session.Position
        lastUpdated := session.LastUpdatedTime
        duration    := session.EndTime
        status      := session.PlaybackStatus

        ; ── Track-change detection (universal) ─────────────────────────────
        ; LastUpdatedTime resets whenever a new track starts, regardless of
        ; what triggered the skip (AHK hotkey, mouse click, phone, etc.).
        ; A forward jump means a new track loaded — set cooldown immediately.
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
        ; songSkipCooldownUntil suppresses this for 2 s after any track change
        ; so the post-skip silence doesn't trigger an unwanted extra skip.
        peak := _GetSongPeak()
        if peak >= 0 {
            if (peak < 0.001) {
                if !State.songSkipLock && A_TickCount >= State.songSkipCooldownUntil {
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
; Returns song's current audio peak (0.0–1.0), or -1 on failure.
; song on Edge is identified by session display name containing "song",
; since it has no dedicated .exe — we can't match by PID.

; song runs as an Edge PWA — no dedicated exe, no display name in WASAPI.
; Strategy: find all msedge.exe sessions, return the highest peak among them.
; If song is the only audio source in Edge this is exact; if multiple Edge
; tabs play simultaneously the max peak is still a valid "is Edge silent?" signal.
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

                if !InStr(procName, "msedge")
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
; Used by tooltip to diagnose which session name song registers under.

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
        if InStr(session.SourceAppUserModelId, CONFIG.SONG)
            session.TogglePlayPause()
    }
}

_SongSkipNext() {
    global State, CONFIG
    for session in State.sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG)
            session.SkipNext()
    }
}

_SongSkipPrevious() {
    global State, CONFIG
    for session in State.sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG)
            session.SkipPrevious()
    }
}
