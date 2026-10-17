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
; It's placed on the monitor of the Chrome window (StateEngine _ChromeMonitor),
; where the fullscreen video is.
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

    pos := Screen.TopRight(_ChromeMonitor(), CLOCK_W, CLOCK_MARGIN_RIGHT, CLOCK_MARGIN_TOP)
    ; Show once so WinSetTransColor has a real window to target, then hide —
    ; passing "Hide" inline with x/y/w/h doesn't reliably keep a new Gui
    ; hidden on its first show.
    ClockGui.Show("NoActivate x" . pos.x . " y" . pos.y . " w" . CLOCK_W . " h" . CLOCK_H)
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
            pos := Screen.TopRight(_ChromeMonitor(), CLOCK_W, CLOCK_MARGIN_RIGHT, CLOCK_MARGIN_TOP)
            ClockGui.Show("NoActivate x" . pos.x . " y" . pos.y)
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
; F6: one line per thing worth checking; problems (gave up, waiting for the
; player, volume errors) only appear when they happen. Early exit when off.

ShowTooltip() {
    global State, CONFIG
    if !State.showTooltip {
        ToolTip()
        return
    }

    v := VideoStatus()
    p := v.page ? v.page : {site: "", playing: false, ready: false, editableFocused: false}
    pageLeveled := p.HasOwnProp("leveled") && p.leveled
    t := ""

    ; ── Video ────────────────────────────────────────────────
    if !v.connected
        t .= "Video:     extension not connected`n"
    else if p.site = ""
        t .= "Video:     no video site`n"
    else
        t .= "Video:     " . p.site . "  " . (p.playing ? "▶ playing" : "⏸ paused") . "  ·  " . v.fs . "`n"
    t .= "Keys:      " . (v.keysOn ? "ON" : "off") . (p.editableFocused ? " (typing)" : "")
        . (v.manualExit ? "  ·  manual exit" : "") . (v.monitorOn ? "" : "  ·  monitor OFF (F7)") . "`n"
    if p.playing && !p.ready && v.fs == "normal"
        t .= "           waiting for the player`n"
    if v.lastGaveUp != ""
        t .= "           fullscreen gave up at " . v.lastGaveUp . "`n"
    t .= "Lossless:  " . (_LosslessActive(_ChromeMonitor()) ? "on" : "off")
        . (v.lossless.pending != "" ? "  ·  " . v.lossless.pending . " when Chrome is back" : "") . "`n"

    ; ── Sound ────────────────────────────────────────────────
    t .= "Volume:    " . (pageLeveled ? "levelled" : "not levelled on this page") . "`n"
    t .= "Speaker:   " . (State.activeSpeaker ? State.activeSpeaker : "—") . "  ·  bass " . (State.bassOn ? "ON" : "off") . "`n"
    t .= "Spotify:   " . _SpotifyLine() . "`n"

    MouseGetPos(&xpos, &ypos)
    ToolTip(RTrim(t, "`n"), xpos + 14, ypos + 14)
}

; "▶ 42s left" (with "· skip zone" in the outro window), "⏸ paused", or "—"
_SpotifyLine() {
    global State, CONFIG
    try {
        for session in State.sessions {
            if !InStr(session.SourceAppUserModelId, CONFIG.SONG)
                continue
            if session.PlaybackStatus != 4
                return "⏸ paused"
            session.UpdateTimelineProperties()
            currentFiletime := 0
            DllCall("GetSystemTimeAsFileTime", "int64*", &currentFiletime)
            unixNow := (currentFiletime - 116444736000000000) // 10000000
            elapsed := unixNow - (session.LastUpdatedTime - 11644473600)  ; Windows epoch → Unix epoch
            livePos := (elapsed >= 0 && elapsed <= 600) ? session.Position + elapsed : session.Position
            remaining := Round(session.EndTime) - Round(livePos)
            return "▶ " . remaining . "s left" . (remaining <= 10 ? "  ·  skip zone" : "")
        }
    }
    return "—"
}
