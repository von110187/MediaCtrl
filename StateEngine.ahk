; ============ STATE ENGINE ============
; Single entry point for all state mutations — monitors pass their session
; snapshot here and never act directly.

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

    ; Harman Kardon: game open + focused → bass on; else off
    if (State.activeSpeaker = "Harman Kardon")
        _UpdateHarmanBass()

    _EvalVideoHotkeys()
}

_UpdateHarmanBass() {
    global State, CONFIG
    prog := State.currentProgram
    shouldOn := false
    for game in CONFIG.GAME_LIST {
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
                pipePos := InStr(entry, "|")  ; "tabId|url"
                newPlayingTabs.Push(pipePos ? SubStr(entry, pipePos + 1) : entry)
            }
        }
        ; Prune seen-tab cache for tabs no longer playable, with two allowances:
        ; 1. Some players (Bilibili) mutate the URL slightly during playback
        ;    (tracking/timestamp params) — use the same lenient substring
        ;    match as Gate 2 below, not exact equality.
        ; 2. A single tick's DOM blip shouldn't forget a tab immediately —
        ;    require a few consecutive misses first.
        ; Deletions collected and applied after the loop since mutating the
        ; Map mid-iteration is unsafe.
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

        ; synthesize iframe-player sites into playingTabs — content script
        ; can't detect their video (cross-origin iframe)
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

    ; Windows' SMTC status for the browser is the browser's own guess about
    ; which <video> backs the OS media session — unreliable when the tracked
    ; element changes (e.g. Douyin swapping <video> on scroll can leave it
    ; stuck reporting "paused"). extPlaying (extension's direct DOM
    ; observation) exists for this; OR it in if either source says "playing".
    ;
    ; Applies unconditionally, including while pendingExitFS is armed. An
    ; earlier version used raw SMTC in that window instead, reasoning it
    ; reacts faster to a genuine pause than extPlaying's round trip — but
    ; that let ANY click anywhere on the page look like "stopped" and trigger
    ; an exit, since raw SMTC can already be stale regardless of what was
    ; clicked. Reliability wins over shaving off latency here.
    if State.matchedSite && !State.matchedSite.iframePlayer
        newBrowserIsPlaying := newBrowserIsPlaying || State.extPlaying

    if newBrowserIsPlaying {
        ; commit immediately, no debounce needed
        State.browserNotPlayingTicks := 0
        if !State.browserIsPlaying {
            State.browserIsPlaying := true
            _EvalVideoHotkeys()
        }
    } else {
        ; only commit after BROWSER_STOP_DEBOUNCE consecutive ticks
        State.browserNotPlayingTicks += 1
        if State.browserIsPlaying && State.browserNotPlayingTicks >= CONFIG.BROWSER_STOP_DEBOUNCE {
            State.browserIsPlaying := false
            ; F5 refresh: audio stopped because page is reloading — unblock re-entry
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
        ; user Alt+Tabbed away — never auto-exit fullscreen here, only
        ; user-initiated hotkeys should do that
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
        ; debounce — a single tick's DOM blip (e.g. Douyin swapping its
        ; <video> mid-feed) shouldn't read as "left the video"; a false exit
        ; can desync fullscreen state until the page is reloaded
        State.urlNotPlayableTicks += 1
        if State.urlNotPlayableTicks < CONFIG.URL_MISS_DEBOUNCE
            return  ; grace period
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

    ; mark entering fullscreen before any sleep, to prevent re-entry if the
    ; polling timer fires mid-sleep during the startup delay
    State.browserInFullScreen := true
    State.manuallyExitedFS   := false
    _SetVideoHotkeys(true)
    UpdateClockVisibility()  ; show now, before the startup-delay Sleep below

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
