; ============ FULLSCREEN CLOCK OVERLAY ============
; Small always-on-top, click-through clock, shown only in fullscreen video
; (fullscreen hides Windows' taskbar clock).
;
; +E0x20 = WS_EX_TRANSPARENT so clicks pass through to the browser and never
; interfere with the extension's click-to-exit. Gui's BackColor is a magenta
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

; Called directly from StateEngine.ahk's _NotifyFullscreen for zero-delay
; show/hide. The SetTimer-driven
; UpdateClockOverlay() below is a once-a-second safety net, not the primary trigger.
UpdateClockVisibility() {
    global ClockGui, ClockTextCtrl, State, _clockShown
    global CLOCK_W, CLOCK_MARGIN_RIGHT, CLOCK_MARGIN_TOP
    if !ClockGui
        return

    if State.machine.state == "fullscreen" {
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

    ; ── Program ──────────────────────────────────────────────
    t .= "PROGRAM`n" . LS
    t .= "Program:  " . (State.currentProgram ? State.currentProgram : "—") . "`n"
    t .= "`n"

    ; ── Video (page-tracked, as reported by the extension) ────
    v := VideoStatus()
    p := v.page ? v.page : {url: "", site: "", playable: false, playing: false, ready: false, editableFocused: false}
    lossless := v.lossless
    t .= "VIDEO`n" . LS
    t .= "Connected:  " . _YesNo(v.connected) . "    Monitor: " . (v.monitorOn ? "On" : "Off") . "`n"
    t .= "URL:        " . (p.url != "" ? SubStr(p.url, 1, 60) : "—") . "`n"
    t .= "Site:       " . (p.site != "" ? p.site : "—") . "`n"
    t .= "Playable:   " . _YesNo(p.playable) . "   Playing: " . _YesNo(p.playing) . "   Ready: " . _YesNo(p.ready) . "`n"
    t .= "Typing:     " . _YesNo(p.editableFocused) . "`n"
    t .= "Fullscreen: " . v.fs . "   Manual exit: " . _YesNo(v.manualExit) . "`n"
    t .= "Video keys: " . (v.keysOn ? "ON" : "OFF") . "`n"
    t .= "Gave up:    " . (v.lastGaveUp != "" ? v.lastGaveUp : "never") . "`n"
    t .= "Lossless:   " . (lossless.on ? "on" : "off") . "   pending: " . (lossless.pending != "" ? lossless.pending : "—")
        . "   detected: " . _YesNo(_LosslessActive()) . "`n"
    t .= "`n"

    ; ── Volume leveler ────────────────────────────────────────
    t .= "VOLUME LEVELER`n" . LS
    t .= "Enabled: " . (CONFIG.VOLUME_LEVELER_ENABLED ? "yes" : "no") . "`n"
    levelerActive := p.site != "" && p.playing
    t .= "Active:  " . (levelerActive ? "yes" : "no (needs matched site + playing)") . "`n"
    livePeak := _GetBrowserPeak()
    t .= "Peak now:   " . (livePeak >= 0 ? Round(livePeak, 4) : "n/a (no " . CONFIG.BROWSER . " session found)") . "`n"
    t .= "Smoothed:   " . _RoundTrim(State.volumeSmoothedPeak, 4) . " (target " . _RoundTrim(CONFIG.VOLUME_LEVELER_TARGET, 4) . ")`n"
    t .= "Multiplier: " . Round(State.volumeMultiplier, 3) . "x`n"
    ; the leveler's last _SetBrowserVolume() result — not re-applied from here
    dbg := State.volumeDebug
    if IsObject(dbg) {
        t .= "Last set:   " . dbg.total . " total, " . dbg.browserSessions . " " . CONFIG.BROWSER . ", " . dbg.volumeSet . " volume-set OK`n"
        if dbg.error != ""
            t .= "Error:      " . dbg.error . "`n"
    }
    t .= "`n"

    ; ── Bridge messages ──────────────────────────────────────
    t .= "BRIDGE (last 15)`n" . LS
    first := Max(1, State.bridgeLog.Length - 14)
    Loop State.bridgeLog.Length - first + 1
        t .= "  " . State.bridgeLog[first + A_Index - 1] . "`n"
    if !State.bridgeLog.Length
        t .= "  (none yet)`n"
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
    t .= _WasapiSessionsCached()
        }
    } catch {
    }

    MouseGetPos(&xpos, &ypos)
    ToolTip(t, xpos + 14, ypos + 14)
}

; The session list walks every WASAPI session, so it's refreshed at most every
; 2 s, and only while the tooltip is shown (this is only called from it).
_WasapiSessionsCached() {
    static text := "", at := 0
    if !at || A_TickCount - at >= 2000 {
        text := _GetWasapiSessionsDebug()
        at := A_TickCount
    }
    return text
}

_YesNo(v) => v ? "yes" : "no"

; Round to N decimals, string-only trim of trailing zeros (no math after
; Round(), or float noise like 0.34999999999999998 reappears).
_RoundTrim(num, decimals := 4) {
    s := Round(num, decimals)
    if InStr(s, ".") {
        s := RTrim(s, "0")
        s := RTrim(s, ".")
    }
    return s
}
