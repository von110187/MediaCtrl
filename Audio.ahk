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
    global CONFIG
    return Wasapi_MaxPeak(CONFIG.SONG)
}


; ============ WASAPI SESSION DEBUG ============
; All WASAPI session names + identifiers, for the tooltip to diagnose which
; session name Spotify registers under.

_GetWasapiSessionsDebug() {
    result := ""
    if Wasapi_ForEachSession("", Visit, &err) < 0
        return "  error: " err
    return result

    Visit(sessionControlPtr, pid, procName) {
        sessionControl2 := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.IAudioSessionControl2)
        ComCall(4,  sessionControlPtr, "ptr*", &namePtr := 0)  ; GetDisplayName
        ComCall(12, sessionControl2,   "ptr*", &idPtr   := 0)  ; GetSessionIdentifier
        name := namePtr ? StrGet(namePtr, "UTF-16") : "(no name)"
        id   := idPtr   ? StrGet(idPtr,   "UTF-16") : "(no id)"
        DllCall("Ole32\CoTaskMemFree", "ptr", namePtr)
        DllCall("Ole32\CoTaskMemFree", "ptr", idPtr)
        result .= "  [" pid " " procName "] " name "`n    " SubStr(id, 1, 60) "`n"
    }
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

    ; the page leveler (Extension/content.js) does the job where it attached
    pageLeveled := State.page && State.page.HasOwnProp("leveled") && State.page.leveled
    active := State.page && State.page.site && State.page.playing && !pageLeveled
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
    global CONFIG
    return Wasapi_MaxPeak(CONFIG.BROWSER)
}

; Sets the WASAPI per-app volume multiplier (0.0-1.0) on every CONFIG.BROWSER
; session. Attenuation only. Returns a diagnostic {total, browserSessions,
; volumeSet, error} for the tooltip — peak-reading and volume-setting query
; different interfaces off the same session pointer, so one can silently
; fail while the other works.
_SetBrowserVolume(multiplier) {
    global CONFIG
    result := {total: 0, browserSessions: 0, volumeSet: 0, error: ""}
    total := Wasapi_ForEachSession(CONFIG.BROWSER, Visit, &err)
    if total < 0
        result.error := err
    else
        result.total := total
    return result

    Visit(sessionControlPtr, *) {
        result.browserSessions += 1
        simpleVolume := ComObjQuery(sessionControlPtr, WASAPI_CLSIDS.ISimpleAudioVolume)
        if !simpleVolume
            return
        ComCall(3, simpleVolume, "float", multiplier, "ptr", 0)  ; ISimpleAudioVolume::SetMasterVolume
        result.volumeSet += 1
    }
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
    ; no session yet — song app open (or not running) but hasn't played anything
    _ActivateSongApp("{Space}", "", 2500, (session) => session.TogglePlayPause())
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
    _ActivateSongApp("^{Right}", "", 2500, (session) => session.SkipNext())
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
    ; No session — activate song app and skip-previous (+ resume if paused) once it's ready
    _ActivateSongApp("^{Left}", "{Space}", 2500, _SongSkipPreviousAction)
}

_SongSkipPreviousAction(session) {
    session.SkipPrevious()
    if session.PlaybackStatus != 4
        session.Play()
}

; Activates the native Spotify app, then performs the requested action.
; Matched by CONFIG.SONG_EXE.
;
; If Spotify isn't running at all, launches it first and polls for an SMTC
; session to appear (i.e. Spotify has actually finished loading and is
; ready) rather than guessing with a fixed sleep. If a session shows up in
; time, sessionAction is called directly on it (reliable — same path as the
; normal case above). If no session ever appears (e.g. a completely empty
; library/queue with nothing to report yet), falls back to focusing the
; window and sending a synthetic key/key2 as a best-effort.
_ActivateSongApp(key, key2 := "", delay := 2500, sessionAction := "") {
    global CONFIG
    winTitle := "ahk_exe " . CONFIG.SONG_EXE
    wasRunning := WinExist(winTitle)

    if !wasRunning {
        if !_LaunchSongApp()
            return
        if !WinWait(winTitle, , 15)
            return

        session := _WaitForSongSession(20000)
        if session && sessionAction {
            try {
                sessionAction(session)
                return
            } catch {
                ; fall through to keystroke path below
            }
        }
    }

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

; Polls Media.GetSessions() until a session matching CONFIG.SONG appears
; (Spotify has loaded and registered SMTC — the same readiness signal the
; rest of the script relies on) or timeoutMs elapses. Refreshes State.sessions
; on success so the caller's next tick already sees it. Returns the matching
; session object, or "" if none appeared in time.
_WaitForSongSession(timeoutMs) {
    global State, CONFIG
    pollInterval := 300
    elapsed := 0
    while elapsed < timeoutMs {
        try {
            sessions := Media.GetSessions()
            for session in sessions {
                if InStr(session.SourceAppUserModelId, CONFIG.SONG) {
                    State.sessions := sessions
                    return session
                }
            }
        } catch {
        }
        Sleep(pollInterval)
        elapsed += pollInterval
    }
    return ""
}

; Launches Spotify via the Windows "App Paths" registry entry (how Explorer/
; Run resolves a bare CONFIG.SONG_EXE without needing a hardcoded install
; path — checks HKCU first since Spotify's per-user installer registers
; there, then HKLM for machine-wide/Store installs). Falls back to Run()'ing
; the bare name in case it's on PATH. Returns true if a launch was
; attempted, false if no path could be resolved.
_LaunchSongApp() {
    global CONFIG
    appPathsKeys := [
        "HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" . CONFIG.SONG_EXE,
        "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" . CONFIG.SONG_EXE
    ]
    for regKey in appPathsKeys {
        try {
            exePath := RegRead(regKey, , "")
            if exePath != "" && FileExist(exePath) {
                Run('"' . exePath . '"')
                return true
            }
        } catch {
        }
    }
    try {
        Run(CONFIG.SONG_EXE)
        return true
    } catch {
    }
    ; last-resort explicit path, e.g. portable install with no registry entry
    try {
        if CONFIG.HasOwnProp("SONG_EXE_PATH") && FileExist(CONFIG.SONG_EXE_PATH) {
            Run('"' . CONFIG.SONG_EXE_PATH . '"')
            return true
        }
    } catch {
    }
    return false
}
