; ============ STATE ENGINE ============
; Single entry point for all state mutations.
; Monitors pass their session snapshot here and never act directly.

UpdateState(sessions) {
    global State
    State.sessions := sessions

    try {
        _UpdateProgramState()
        _UpdateUrlState()
        _UpdateMediaState(sessions)
        _UpdateAdaptiveTimer()
    } catch as err {
        ; Swallow COM errors during session churn — next tick recovers
    }
}

; ── Active program ────────────────────────────────────────────────────────────

_UpdateProgramState() {
    global State
    try {
        prog := WinGetProcessName("A")
    } catch {
        prog := ""
    }
    if State.currentProgram != prog {
        State.currentProgram := prog
        _OnProgramChanged()
    }
}

_OnProgramChanged() {
    global State, CONFIG

    ; Bass: Harman Kardon tracks whether current focused program is a running game.
    ; Game open + focused → bass on; switched away OR game closed → bass off.
    if (State.activeSpeaker = "Harman Kardon")
        _UpdateHarmanBass()

    ; Video: re-evaluate hotkeys whenever program focus changes
    _EvalVideoHotkeys()
}

_UpdateHarmanBass() {
    global State, CONFIG
    prog := State.currentProgram
    shouldOn := false
    for game in CONFIG.GAME_LIST {
        ; Game must be running AND be the focused program
        if ProcessExist(game . ".exe") && InStr(prog, game) {
            shouldOn := true
            break
        }
    }
    _SetBass(shouldOn)
}

; ── URL state from bridge ─────────────────────────────────────────────────────

_UpdateUrlState() {
    global State

    urlFile        := A_Temp . "\ahk_current_url.txt"
    tabsFile       := A_Temp . "\ahk_playing_tabs.txt"
    cor5File       := A_Temp . "\ahk_cor5_href.txt"

    try {
        newUrl := Trim(FileRead(urlFile))
    } catch {
        newUrl := State.currentUrl
    }

    try {
        raw  := Trim(FileRead(tabsFile))
        newPlayingTabs := []
        if raw != "" {
            for entry in StrSplit(raw, "`n") {
                ; Each entry is "tabId|url" — extract just the url part
                pipePos := InStr(entry, "|")
                newPlayingTabs.Push(pipePos ? SubStr(entry, pipePos + 1) : entry)
            }
        }
        ; Prune seen-tab cache for any tabs that are no longer playable
        for seenUrl in State.startupDelaySeen {
            stillPresent := false
            for tabUrl in newPlayingTabs {
                if seenUrl = tabUrl {
                    stillPresent := true
                    break
                }
            }
            if !stillPresent
                State.startupDelaySeen.Delete(seenUrl)
        }

        ; Synthesize iframe-player sites into playingTabs — content script can't detect
        ; their video (cross-origin iframe), so we add the current URL if it matches
        matchedSite := _FindMatchedSite(newUrl)
        if matchedSite && matchedSite.iframePlayer && newUrl != "" {
            alreadyIn := false
            for tabUrl in newPlayingTabs {
                if tabUrl = newUrl {
                    alreadyIn := true
                    break
                }
            }
            if !alreadyIn
                newPlayingTabs.Push(newUrl)
        }

        State.playingTabs := newPlayingTabs
    } catch {
        ; keep last known
    }

    try {
        State.cor5Href := Trim(FileRead(cor5File))
    } catch {
        ; keep last known
    }

    State.currentUrl  := newUrl
    State.matchedSite := _FindMatchedSite(newUrl)
    _EvalVideoHotkeys()
}

_FindMatchedSite(url) {
    global CONFIG
    for name, site in CONFIG.SITES.OwnProps() {
        if InStr(url, site.url)
            return site
    }
    return ""
}

; ── Media session state ───────────────────────────────────────────────────────

_UpdateMediaState(sessions) {
    global State, CONFIG

    newBrowserIsPlaying  := false
    newSongIsPlaying := false
    newBrowserStatus := 0

    for session in sessions {
        rawId := session.SourceAppUserModelId
        if InStr(rawId, CONFIG.BROWSER) {
            newBrowserStatus     := session.PlaybackStatus
            newBrowserIsPlaying  := newBrowserStatus = 4
        } else if InStr(rawId, CONFIG.SONG)
            newSongIsPlaying := session.PlaybackStatus = 4
    }

    State.browserPlaybackStatus := newBrowserStatus

    if newBrowserIsPlaying {
        ; Playing — commit immediately, reset debounce counter
        State.browserNotPlayingTicks := 0
        if !State.browserIsPlaying {
            State.browserIsPlaying := true
            _EvalVideoHotkeys()
        }
    } else {
        ; Not playing — only commit after CHROME_STOP_DEBOUNCE consecutive ticks
        State.browserNotPlayingTicks += 1
        if State.browserIsPlaying && State.browserNotPlayingTicks >= CONFIG.CHROME_STOP_DEBOUNCE {
            State.browserIsPlaying := false
            ; F5 refresh: audio stopped because page is reloading — unblock auto re-entry
            if State.pendingF5 {
                State.pendingF5        := false
                State.manuallyExitedFS := false
            }
            _EvalVideoHotkeys()
        }
    }

    State.songIsPlaying := newSongIsPlaying
}

; ── Video hotkey evaluation ───────────────────────────────────────────────────
; Rules:
;   1. Not browser, not matched site, or not in playable tabs → disable (exit FS if needed)
;   2. browser + matched + playing + not FS + user manually exited → keep hotkeys ON, no re-enter
;   3. browser + matched + playing + not FS + not manually exited → enter FS + hotkeys ON
;   4. browser + matched + playing + in FS → hotkeys ON
;   5. browser + matched + not playing + not FS → hotkeys OFF; also clear manuallyExitedFS
;   6. browser + matched + not playing + in FS → keep hotkeys ON (user paused mid-watch)

_EvalVideoHotkeys() {
    global State, CONFIG

    if !State.monitorVideo {
        _SetVideoHotkeys(false)
        return
    }

    prog     := State.currentProgram
    site     := State.matchedSite
    inBrowser := InStr(prog, CONFIG.BROWSER)

    ; Gate 1 — must be song browser on a matched site
    if !inBrowser || !site {
        ; User has Alt+Tabbed away from browser (or switched to another program).
        ; Never auto-exit fullscreen here — only user-initiated hotkeys should do that.
        ; Just disable video hotkeys and leave fullscreen state untouched.
        if State.browserInFullScreen {
            _SetVideoHotkeys(false)
            return
        }
        _SetVideoHotkeys(false)
        State.manuallyExitedFS := false
        State.pendingExitFS    := false
        return
    }

    ; Gate 2 — current URL must be a playable tab (has media element)
    ; Skip for iframe-player sites — content script can't see into cross-origin iframes
    urlInPlayable := site.iframePlayer
    if !urlInPlayable {
        for tabUrl in State.playingTabs {
            if (State.currentUrl = tabUrl) || InStr(State.currentUrl, tabUrl) || InStr(tabUrl, State.currentUrl) {
                urlInPlayable := true
                break
            }
        }
    }

    if !urlInPlayable {
        if State.browserInFullScreen
            _ExitFullscreen()
        _SetVideoHotkeys(false)
        State.manuallyExitedFS := false
        State.pendingExitFS    := false
        return
    }

    ; ── We are on a valid playable tab in browser ──────────────────────────────
    if State.browserIsPlaying {
        if State.browserInFullScreen {
            ; Playing in fullscreen — normal, hotkeys on
            _SetVideoHotkeys(true)
        } else if State.manuallyExitedFS {
            ; User manually exited FS while playing — keep hotkeys on, don't re-enter
            _SetVideoHotkeys(true)
        } else {
            ; Playing but not in FS and didn't manually exit — auto-enter fullscreen
            _EnterFullscreen()
        }
    } else {
        ; Audio stopped — check if exit was deferred
        if State.pendingExitFS {
            State.pendingExitFS := false
            if State.browserInFullScreen
                _ExitFullscreenByUser()
            return
        }
        if State.browserInFullScreen {
            ; Paused while in FS — keep hotkeys on so user can interact
            _SetVideoHotkeys(true)
        } else {
            ; Not playing, not in FS — done, disable hotkeys and reset flag
            _SetVideoHotkeys(false)
            State.manuallyExitedFS := false
        }
    }
}

; ── Adaptive timer ────────────────────────────────────────────────────────────

_UpdateAdaptiveTimer() {
    global State, CONFIG

    anyActive := false
    for session in State.sessions {
        if session.PlaybackStatus = 4 {
            anyActive := true
            break
        }
    }

    interval := anyActive ? CONFIG.TIMER_ACTIVE : CONFIG.TIMER_IDLE
    if State.currentInterval != interval {
        State.currentInterval := interval
        SetTimer(MonitorTick, interval)
    }
}

; ── Internal fullscreen helpers ───────────────────────────────────────────────

_EnterFullscreen() {
    global State, CONFIG
    site := State.matchedSite
    if !site || State.browserInFullScreen
        return

    if site.mouseCenter
        MouseMove(4000, A_ScreenHeight/2)

    ; Mark as entering fullscreen BEFORE any sleep — prevents re-entry
    ; during the startup delay when the polling timer fires mid-sleep
    State.browserInFullScreen := true
    State.manuallyExitedFS   := false
    _SetVideoHotkeys(true)

    if site.startupDelay {
        if !State.startupDelaySeen.Has(State.currentUrl) {
            State.startupDelaySeen.Set(State.currentUrl, true)
            Sleep(site.sleepMs)
        }
    }

    Send(CONFIG.LOSSLESS_HOTKEY)
    Send(site.fsKey)
}

; Called by user hotkeys (b, Esc, LButton, F8, ~^w, F7).
; Sets manuallyExitedFS so _EvalVideoHotkeys won't auto re-enter.
_ExitFullscreenByUser() {
    global State, CONFIG
    site := State.matchedSite
    if !site || !State.browserInFullScreen
        return

    if site.mouseCenter
        MouseMove(A_ScreenWidth/2, A_ScreenHeight/2)

    Send(CONFIG.LOSSLESS_HOTKEY)
    Send(site.fsKey)
    State.browserInFullScreen := false
    State.manuallyExitedFS   := true  ; tell eval not to re-enter
    _EvalVideoHotkeys()
}

; Called automatically (program switch, URL change, monitorVideo off).
; Does NOT set manuallyExitedFS.
_ExitFullscreen() {
    global State, CONFIG
    site := State.matchedSite
    if !site || !State.browserInFullScreen
        return

    if site.mouseCenter
        MouseMove(A_ScreenWidth/2, A_ScreenHeight/2)

    Send(CONFIG.LOSSLESS_HOTKEY)
    Send(site.fsKey)
    State.browserInFullScreen := false
    ; manuallyExitedFS stays as-is — _EvalVideoHotkeys will clear it if needed
    _EvalVideoHotkeys()
}

; ── Hotkey toggles ────────────────────────────────────────────────────────────

_SetVideoHotkeys(enable) {
    global State
    if State.videoHotkeys = enable
        return
    State.videoHotkeys := enable
    for key in ["$b", "$w", "$a", "$s", "$d", "$1", "$2", "$3", "$4", "$Esc", "$F1", "$F2", "$F3", "$F5"]
        Hotkey(key, enable ? "On" : "Off")
}

; ── Bass helpers ──────────────────────────────────────────────────────────────

_SetBass(enable) {
    global State
    if State.bassOn = enable
        return
    State.bassOn := enable
    Send(enable ? "^!{F12}" : "^!{F11}")
}
