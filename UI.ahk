; ============ FULLSCREEN CLOCK OVERLAY ============
; Small always-on-top, click-through clock, shown only in fullscreen video
; (fullscreen hides Windows' taskbar clock).
;
; +E0x20 = WS_EX_TRANSPARENT so clicks pass through to the browser and never
; interfere with LButton fullscreen-exit. Gui's BackColor is a magenta
; color-key that WinSetTransColor makes fully transparent, so only the text
; floats over the video.
;
; CLOCK_MARGIN_RIGHT: increase to move the clock further left (e.g. to clear
; Douyin's like/comment/share icon column on the right edge in fullscreen).
CLOCK_W               := 120
CLOCK_H               := 40
CLOCK_MARGIN_RIGHT     := 65
CLOCK_MARGIN_TOP       := 0
CLOCK_TRANSPARENT_KEY  := "000000"

ClockGui      := ""
ClockTextCtrl := ""
_clockShown   := false

InitClockOverlay() {
    global ClockGui, ClockTextCtrl
    global CLOCK_W, CLOCK_H, CLOCK_MARGIN_RIGHT, CLOCK_MARGIN_TOP, CLOCK_TRANSPARENT_KEY

    ClockGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
    ClockGui.BackColor := CLOCK_TRANSPARENT_KEY
    ClockGui.MarginX := 0
    ClockGui.MarginY := 0

    ClockGui.SetFont("s20 cWhite Bold", "Segoe UI")
    ClockTextCtrl := ClockGui.AddText("Center w" . CLOCK_W . " h" . CLOCK_H, FormatTime(, "h:mm"))

    x := A_ScreenWidth - CLOCK_W - CLOCK_MARGIN_RIGHT
    ; Show once so WinSetTransColor has a real window to target, then hide —
    ; passing "Hide" inline with x/y/w/h doesn't reliably keep a new Gui
    ; hidden on its first show.
    ClockGui.Show("NoActivate x" . x . " y" . CLOCK_MARGIN_TOP . " w" . CLOCK_W . " h" . CLOCK_H)
    WinSetTransColor(CLOCK_TRANSPARENT_KEY, "ahk_id " . ClockGui.Hwnd)
    ClockGui.Hide()
}

; Called directly from StateEngine.ahk's _EnterFullscreen/_ExitFullscreenByUser/
; _ExitFullscreen for zero-delay show/hide. The SetTimer-driven
; UpdateClockOverlay() below is a once-a-second safety net, not the primary trigger.
UpdateClockVisibility() {
    global ClockGui, ClockTextCtrl, State, _clockShown
    global CLOCK_W, CLOCK_MARGIN_RIGHT, CLOCK_MARGIN_TOP
    if !ClockGui
        return

    if State.browserInFullScreen {
        if !_clockShown {
            ClockTextCtrl.Value := FormatTime(, "h:mm")
            x := A_ScreenWidth - CLOCK_W - CLOCK_MARGIN_RIGHT
            ClockGui.Show("NoActivate x" . x . " y" . CLOCK_MARGIN_TOP)
            _clockShown := true
        }
    } else if _clockShown {
        ClockGui.Hide()
        _clockShown := false
    }
}

UpdateClockOverlay() {
    global ClockGui, ClockTextCtrl
    if !ClockGui
        return

    ClockTextCtrl.Value := FormatTime(, "h:mm")
    UpdateClockVisibility()
}

; ============ TOOLTIP ============
; Debug-relevant state only. Early exit when tooltip is off.

ShowTooltip() {
    global State, CONFIG
    if !State.showTooltip {
        ToolTip()
        return
    }

    LS := "────────────────────────`n"
    t  := ""

    ; ── Program / URL ────────────────────────────────────────
    t .= "PROGRAM`n" . LS
    t .= "Program:  " . (State.currentProgram ? State.currentProgram : "—") . "`n"
    t .= "URL:      " . (State.currentUrl     ? SubStr(State.currentUrl, 1, 60) : "—") . "`n"
    t .= "Matched:  " . (State.matchedSite    ? State.matchedSite.url : "—") . "`n"
    t .= "`n"

    ; ── browser ───────────────────────────────────────────────
    t .= StrUpper(CONFIG.BROWSER) . "`n" . LS
    t .= "Playing:    " . (State.browserIsPlaying    ? "▶ yes" : "⏸ no") . "`n"
    t .= "Fullscreen: " . (State.browserInFullScreen ? "yes"   : "no")   . "`n"
    t .= "`n"

    ; ── Volume leveler ────────────────────────────────────────
    t .= "VOLUME LEVELER`n" . LS
    t .= "Enabled: " . (CONFIG.VOLUME_LEVELER_ENABLED ? "yes" : "no") . "`n"
    levelerActive := State.matchedSite && State.browserIsPlaying
    t .= "Active:  " . (levelerActive ? "yes" : "no (needs matched site + playing)") . "`n"
    livePeak := _GetBrowserPeak()
    t .= "Peak now:   " . (livePeak >= 0 ? Round(livePeak, 4) : "n/a (no " . CONFIG.BROWSER . " session found)") . "`n"
    t .= "Smoothed:   " . Round(State.volumeSmoothedPeak, 4) . " (target " . CONFIG.VOLUME_LEVELER_TARGET . ")`n"
    t .= "Multiplier: " . Round(State.volumeMultiplier, 3) . "x`n"
    ; fresh diagnostic every refresh (re-applies current multiplier, harmless)
    ; rather than showing stale volumeDebug
    dbg := _SetBrowserVolume(State.volumeMultiplier)
    t .= "Sessions:   " . dbg.total . " total, " . dbg.browserSessions . " " . CONFIG.BROWSER . ", " . dbg.volumeSet . " volume-set OK`n"
    if dbg.error != ""
        t .= "Error:      " . dbg.error . "`n"
    t .= "`n"

    ; ── Video hotkeys ────────────────────────────────────────
    t .= "VIDEO HOTKEYS`n" . LS
    t .= "Enabled:  " . (State.videoHotkeys ? "ON" : "OFF") . "`n"
    t .= "Monitor:  " . (State.monitorVideo ? "On" : "Off") . "`n"
    t .= "`n"

    ; ── Playable tabs ────────────────────────────────────────
    t .= "PLAYABLE TABS (" . State.playingTabs.Length . ")`n" . LS
    if State.playingTabs.Length > 0 {
        for url in State.playingTabs
            t .= "  • " . SubStr(url, 1, 55) . "`n"
    } else {
        t .= "  (none)`n"
    }
    t .= "`n"

    ; ── Speaker / Bass ───────────────────────────────────────
    t .= "SPEAKER`n" . LS
    t .= "Speaker: " . (State.activeSpeaker ? State.activeSpeaker : "—") . "`n"
    t .= "Bass:    " . (State.bassOn ? "ON" : "OFF") . "`n"
    t .= "`n"

    ; ── Spotify ───────────────────────────────────────────────
    t .= StrUpper(CONFIG.SONG) . "`n" . LS
    t .= "Playing: " . (State.songIsPlaying ? "▶ yes" : "⏸ no") . "`n"
    try {
        for session in State.sessions {
            if !InStr(session.SourceAppUserModelId, CONFIG.SONG)
                continue
            session.UpdateTimelineProperties()
            dur    := session.EndTime
            pos    := session.Position
            lastUp := session.LastUpdatedTime

            if session.PlaybackStatus = 4 {
                currentFiletime := 0
                DllCall("GetSystemTimeAsFileTime", "int64*", &currentFiletime)
                unixNow   := (currentFiletime - 116444736000000000) // 10000000
                lastUpUnix := lastUp - 11644473600  ; convert Windows epoch → Unix epoch
                elapsed   := unixNow - lastUpUnix
                livePos   := (elapsed >= 0 && elapsed <= 600) ? pos + elapsed : pos
            } else {
                livePos := pos
            }
            remaining := Round(dur) - Round(livePos)
            t .= "Remaining: " . remaining . "s" . (remaining <= 10 ? " ← SKIP ZONE" : "") . "`n"
            t .= "Status:    " . session.PlaybackStatus . " (4=playing 5=changing)`n"
            peak := _GetSongPeak()
            t .= "Peak:      " . (peak >= 0 ? Round(peak, 4) : "n/a (session not found)") . "`n"
    t .= "`nWASAPI SESSIONS`n" . LS
    t .= _GetWasapiSessionsDebug()
        }
    } catch {
    }

    MouseGetPos(&xpos, &ypos)
    ToolTip(t, xpos + 14, ypos + 14)
}
