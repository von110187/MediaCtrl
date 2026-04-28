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
    t .= "CHROME`n" . LS
    t .= "Playing:    " . (State.browserIsPlaying    ? "▶ yes" : "⏸ no") . "`n"
    t .= "Fullscreen: " . (State.browserInFullScreen ? "yes"   : "no")   . "`n"
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

    ; ── song ──────────────────────────────────────────────
    t .= "SONG`n" . LS
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
