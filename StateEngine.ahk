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
    extPlayingFile := A_Temp . "\ahk_ext_playing.txt"

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
        ; Prune seen-tab cache for tabs no longer playable. Two wrinkles vs.
        ; a plain set-difference:
        ; 1. Some players (e.g. Bilibili) mutate the URL slightly during
        ;    playback (tracking/timestamp params), so exact equality could
        ;    make an already-seen video look new. Use the same lenient
        ;    substring match as Gate 2 below.
        ; 2. A single tick where the tab briefly drops out of the reported
        ;    list (e.g. a DOM blip on pause/resume) shouldn't forget it
        ;    immediately — require a few consecutive misses first.
        ;
        ; Deletions are collected and applied after the loop — mutating
        ; the Map mid-iteration is unsafe and would abort this try block
        ; before State.playingTabs is set below.
        toForget := []
        for seenUrl in State.startupDelaySeen {
            stillPresent := false
            for tabUrl in newPlayingTabs {
                if (seenUrl = tabUrl) || InStr(seenUrl, tabUrl) || InStr(tabUrl, seenUrl) {
                    stillPresent := true
                    break
                }
            }
            if stillPresent {
                if State.startupDelayMissCount.Has(seenUrl)
                    State.startupDelayMissCount.Delete(seenUrl)
            } else {
                misses := State.startupDelayMissCount.Has(seenUrl) ? State.startupDelayMissCount[seenUrl] : 0
                misses += 1
                if misses >= 3 {
                    toForget.Push(seenUrl)
                } else {
                    State.startupDelayMissCount[seenUrl] := misses
                }
            }
        }
        for seenUrl in toForget {
            State.startupDelaySeen.Delete(seenUrl)
            State.startupDelayMissCount.Delete(seenUrl)
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
    } catch as err {
        try FileAppend(A_Now . " _UpdateUrlState failed: " . err.Message . " (playingTabs kept at " . State.playingTabs.Length . ")`n", A_Temp . "\ahk_urlstate_errors.log")
        ; keep last known
    }

    try {
        State.cor5Href := Trim(FileRead(cor5File))
    } catch {
        ; keep last known
    }

    try {
        State.extPlaying := Trim(FileRead(extPlayingFile)) = "1"
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

; Same lenient substring match as the Gate 2 playability check — keeps URL
; identity consistent so minor URL drift doesn't make a seen video look new.
_UrlSeenForDelay(url) {
    global State
    for seenUrl in State.startupDelaySeen {
        if (url = seenUrl) || InStr(url, seenUrl) || InStr(seenUrl, url)
            return true
    }
    return false
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

    ; Windows' SMTC status for the browser is Chrome's own guess about which
    ; <video> element backs the OS media session — unreliable specifically
    ; when the tracked element changes (Douyin swapping <video> elements as
    ; you scroll can leave it stuck reporting "paused" forever). That's why
    ; State.extPlaying (the extension's own direct DOM observation) exists,
    ; and why it's used as a full override below during normal/passive
    ; monitoring — it can't get stuck like SMTC can.
    ;
    ; But for a user-initiated pause (LButton/b, both of which set
    ; State.pendingExitFS the instant they fire) there's no video-swap
    ; ambiguity at all — it's a plain pause of whatever's already correctly
    ; playing in fullscreen — and for that specific transition, raw SMTC
    ; turns out to react *faster* than the extension's bridge (content.js →
    ; runtime message → background.js → WebSocket → Node → temp file → next
    ; AHK tick has more hops than Chrome's own direct SMTC relay). Routing
    ; this case through the override was adding a real, noticeable delay
    ; between the click and fullscreen actually exiting. So: while a manual
    ; exit is already pending, skip the override and use the faster raw
    ; value; otherwise (normal passive monitoring, where the swap bug
    ; actually lives) keep using the safer extPlaying override.
    if State.matchedSite && !State.matchedSite.iframePlayer && !State.pendingExitFS
        newBrowserIsPlaying := State.extPlaying

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

    if urlInPlayable {
        State.urlNotPlayableTicks := 0
    } else {
        ; Debounce — a single tick's DOM blip (e.g. Douyin swapping its <video>
        ; element mid-feed-rotation during a long idle stretch) shouldn't be
        ; treated as "left the video" immediately. Sending a real exit-fullscreen
        ; keystroke on a false alarm can desync AHK's fullscreen state from the
        ; page's actual state, recoverable only by reloading the page. Require
        ; a few consecutive misses first, same pattern as browserNotPlayingTicks.
        State.urlNotPlayableTicks += 1
        if State.urlNotPlayableTicks < CONFIG.URL_MISS_DEBOUNCE
            return  ; grace period — leave fullscreen/hotkeys state untouched this tick
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
    UpdateClockVisibility()  ; show now — before the startup-delay Sleep below

    if site.startupDelay {
        if !_UrlSeenForDelay(State.currentUrl) {
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
    UpdateClockVisibility()
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
    UpdateClockVisibility()
    _EvalVideoHotkeys()
}

; ── Hotkey toggles ────────────────────────────────────────────────────────────

_SetVideoHotkeys(enable) {
    global State
    if State.videoHotkeys = enable
        return
    State.videoHotkeys := enable
    for key in ["$b", "$w", "$a", "$s", "$d", "$0", "$1", "$2", "$3", "$4", "$Esc", "$F1", "$F2", "$F3", "$F5"]
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
