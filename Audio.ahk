; ============ MONITOR AUDIO ============
; Called every tick — Spotify (native app) outro logic only.

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
; Track changes (hotkey, mouse, phone) are detected by LastUpdatedTime
; jumping forward, arming a cooldown so post-skip silence isn't misread as
; a silent outro. LastUpdatedTime is Windows FILETIME ÷ 10,000,000 (epoch
; Jan 1 1601) — subtract 11644473600 to convert to Unix epoch.

_CheckSongOutro(session) {
    global State
    try {
        session.UpdateTimelineProperties()
        reportedPos := session.Position
        lastUpdated := session.LastUpdatedTime
        duration    := session.EndTime
        status      := session.PlaybackStatus

        ; ── Track-change detection (universal) ─────────────────────────────
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
; Returns Spotify's audio peak (0.0-1.0), or -1 on failure. Spotify runs as
; the native desktop app, so this matches its own Spotify.exe WASAPI
; session(s) directly (CONFIG.SONG = "spotify" matches the process name).
_GetSongPeak() {
    global WASAPI_CLSIDS, CONFIG

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

                if !InStr(procName, CONFIG.SONG)
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
; All WASAPI session names + identifiers, for the tooltip to diagnose which
; session name Spotify registers under.

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
; ============ VOLUME LEVELER ============
; Reactively attenuates the browser's per-app volume so videos recorded
; louder/quieter than each other sound roughly consistent when scrolling a
; feed. Attenuation-only — WASAPI can scale a session down but never boost
; it past its own peak, so this evens out occasional loud videos rather than
; matching loudness bidirectionally.
;
; Runs only while actively watching a configured site; resets the browser to
; full volume otherwise so it doesn't stay quiet after navigating away.

_UpdateVolumeLeveler() {
    global State, CONFIG

    if !CONFIG.VOLUME_LEVELER_ENABLED
        return

    active := State.matchedSite && State.browserIsPlaying
    if !active {
        if State.volumeMultiplier != 1.0 {
            State.volumeMultiplier   := 1.0
            State.volumeSmoothedPeak := 0.0
            State.volumeDebug := _SetBrowserVolume(1.0)
        }
        return
    }

    peak := _GetBrowserPeak()
    if peak < 0
        return  ; couldn't read a session this tick

    ; EMA smooths out quick dialogue gaps
    a := CONFIG.VOLUME_LEVELER_SMOOTHING
    State.volumeSmoothedPeak := (State.volumeSmoothedPeak * (1 - a)) + (peak * a)

    if State.volumeSmoothedPeak < 0.01 {
        targetMultiplier := 1.0  ; avoid division by zero during silence
    } else {
        targetMultiplier := CONFIG.VOLUME_LEVELER_TARGET / State.volumeSmoothedPeak
    }

    targetMultiplier := Max(CONFIG.VOLUME_LEVELER_MIN, Min(1.0, targetMultiplier))

    ; step limit for a smooth transition toward the target
    error := targetMultiplier - State.volumeMultiplier
    if Abs(error) < CONFIG.VOLUME_LEVELER_DEADZONE
        return

    step  := CONFIG.VOLUME_LEVELER_STEP
    delta := error > 0 ? Min(error, step) : Max(error, -step)

    newMultiplier := State.volumeMultiplier + delta
    newMultiplier := Max(CONFIG.VOLUME_LEVELER_MIN, Min(1.0, newMultiplier))

    if Abs(newMultiplier - State.volumeMultiplier) < 0.005
        return

    State.volumeMultiplier := newMultiplier
    State.volumeDebug := _SetBrowserVolume(newMultiplier)
}

; Returns the browser's current audio peak (0.0-1.0), the loudest of all
; CONFIG.BROWSER WASAPI sessions (a tab's audio can live in any renderer-
; process session under Chromium's site-isolation). -1 on failure/no session.
_GetBrowserPeak() {
    global WASAPI_CLSIDS, CONFIG

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

                if !InStr(procName, CONFIG.BROWSER)
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

; Sets the WASAPI per-app volume multiplier (0.0-1.0) on every CONFIG.BROWSER
; session. Attenuation only. Returns a diagnostic {total, browserSessions,
; volumeSet, error} for the tooltip — peak-reading and volume-setting query
; different interfaces off the same session pointer, so one can silently
; fail while the other works.
_SetBrowserVolume(multiplier) {
    global WASAPI_CLSIDS, CONFIG
    result := {total: 0, browserSessions: 0, volumeSet: 0, error: ""}

    try {
        enumerator := ComObject(WASAPI_CLSIDS.MMDeviceEnumerator, WASAPI_CLSIDS.IMMDeviceEnumerator)
        ComCall(4, enumerator, "int", 0, "int", 1, "ptr*", &devicePtr := 0)

        sessionManagerGUID := Buffer(16)
        DllCall("Ole32\CLSIDFromString", "Str", WASAPI_CLSIDS.IAudioSessionManager2, "Ptr", sessionManagerGUID)
        ComCall(3, devicePtr, "ptr", sessionManagerGUID, "int", 23, "ptr", 0, "ptr*", &sessionManagerPtr := 0)
        ComCall(5, sessionManagerPtr, "ptr*", &sessionEnumPtr := 0)
        ComCall(3, sessionEnumPtr, "int*", &count := 0)
        result.total := count

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

                if !InStr(procName, CONFIG.BROWSER)
                    continue

                result.browserSessions += 1

                simpleVolume := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.ISimpleAudioVolume)
                if !simpleVolume
                    continue

                ComCall(3, simpleVolume, "float", multiplier, "ptr", 0)  ; ISimpleAudioVolume::SetMasterVolume
                simpleVolume := ""
                result.volumeSet += 1
            } finally {
                ObjRelease(sessionControlPtr)
            }
        }

        ObjRelease(sessionEnumPtr)
        ObjRelease(sessionManagerPtr)
        ObjRelease(devicePtr)
    } catch as e {
        result.error := e.Message
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
    ; no session yet — song app open but hasn't played anything
    _ActivateSongApp("{Space}")
}

_SongSkipNext() {
    global State, CONFIG
    for session in State.sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG) {
            session.SkipNext()
            return
        }
    }
    ; No session — activate song app and send Ctrl+Right
    _ActivateSongApp("^{Right}")
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
    ; No session — activate song app and send Ctrl+Left then Space
    _ActivateSongApp("^{Left}", "{Space}")
}

; Activates the native Spotify app window, sends a key (and optional second
; key after a delay), then restores focus. Matched by CONFIG.SONG_EXE.
_ActivateSongApp(key, key2 := "", delay := 2500) {
    global CONFIG
    winTitle := "ahk_exe " . CONFIG.SONG_EXE
    if WinExist(winTitle) {
        prevWin := WinExist("A")
        WinActivate(winTitle)
        WinWaitActive(winTitle, , 1)
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
