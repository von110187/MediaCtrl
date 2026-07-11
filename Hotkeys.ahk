; ============ HOTKEYS ============

; ── F6: Toggle tooltip ────────────────────────────────────────────────────────
F6:: {
    global State
    State.showTooltip := !State.showTooltip
    if !State.showTooltip
        ToolTip()
}

; ── F7: Toggle monitorVideo ───────────────────────────────────────────────────
F7:: {
    global State
    State.monitorVideo := !State.monitorVideo
    if !State.monitorVideo {
        if State.browserInFullScreen
            _ExitFullscreenByUser()
        _SetVideoHotkeys(false)
    } else {
        ; Toggled back on — clear the manual-exit flag so _EvalVideoHotkeys
        ; can auto re-enter fullscreen if conditions are met
        State.manuallyExitedFS := false
        _EvalVideoHotkeys()
    }
    if !State.showTooltip {
        ToolTip(State.monitorVideo ? "Monitor: On" : "Monitor: Off")
        SetTimer(() => ToolTip(), -1000)
    }
}

; ── F8: Exit fullscreen + trigger next-episode button ────────────────────────
; Reads the <a class="cor5"> href pushed by the extension and navigates directly.
; Falls back to MouseClick if no href is available.
; Always ends with MouseMove to screen centre.
F8:: {
    global State, CONFIG
    if State.browserInFullScreen
        _ExitFullscreenByUser()
    Sleep(300)

    if State.cor5Href != "" {
        ; Build absolute URL from the stored href (may be relative like /watch/...)
        baseUrl := RegExReplace(State.currentUrl, "(https?://[^/]+).*", "$1")
        nextUrl := (SubStr(State.cor5Href, 1, 4) = "http") ? State.cor5Href : baseUrl . State.cor5Href
        SendCommand("navigate_" . nextUrl)
    } else {
        MouseClick("Left", 3360, 565)
    }

    MouseMove(A_ScreenWidth / 2, A_ScreenHeight / 2)
}

; ── F9 / F10: Manual bass toggle ─────────────────────────────────────────────
F9::  _SetBass(false)
F10:: _SetBass(true)

; ── Volume ────────────────────────────────────────────────────────────────────
F13::  Volume_Down
F14::  Volume_Up
PgDn:: Volume_Down
PgUp:: Volume_Up

; ── Brightness via Twinkle Tray ──────────────────────────────────────────────
End::  Send("{F15}")
Home:: Send("{F16}")

; ── Media keys ───────────────────────────────────────────────────────────────
$Media_Play_Pause:: _SongTogglePlayPause()
$Media_Next::       _SongSkipPrevious()   ; next button → skip previous
$Media_Prev::       Run("shutdown.exe /s /f /t 0")
$Insert::           _SongSkipNext()

; ── ZZZ launcher ─────────────────────────────────────────────────────────────
$AppsKey:: {
    if ProcessExist("ZenlessZoneZero.exe")
        return
    Run('"D:\Program Files\Epic Games\ZenlessZoneZero\games\ZenlessZoneZero Game\ZenlessZoneZero.exe"')
}

; ── LButton: exit fullscreen when clicking the <video> element ────────────────
; Only acts when already in fullscreen and browser was playing, and the click
; itself landed on the page's <video> element (not comments, likes, share
; buttons, the seek bar, etc). AHK can't inspect the page DOM directly, so
; content.js reports the click's target through the extension → WebSocket
; bridge into ahk_video_click.txt.
;
; That report can't be read synchronously here — it has to travel content
; script → background → WebSocket → file, which lands a little while after
; this hotkey fires. So the flag file is cleared immediately (wiping out any
; stale report from an earlier, unrelated click) and re-checked a moment
; later once the round trip has had time to land.
~LButton:: {
    global State
    try FileDelete(A_Temp . "\ahk_video_click.txt")

    if !State.browserInFullScreen
        return
    if !State.browserIsPlaying
        return
    SetTimer(_CheckVideoClickExit, -200)
}

_CheckVideoClickExit() {
    global State
    if !State.browserInFullScreen || !State.browserIsPlaying
        return
    try {
        if Trim(FileRead(A_Temp . "\ahk_video_click.txt")) = "1"
            _ExitFullscreenByUser()
    } catch {
        ; no report arrived — not a video click (or extension disconnected)
    }
}

; ── Ctrl+W: send losslessHotkey when in fullscreen, then let browser close the tab ─
~^w:: {
    global State, CONFIG
    if !State.monitorVideo
        return
    if InStr(State.currentProgram, CONFIG.BROWSER) && State.matchedSite && State.browserInFullScreen {
        Send(CONFIG.LOSSLESS_HOTKEY)
        State.browserInFullScreen := false
        State.manuallyExitedFS   := true
    }
}
