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

; ── LButton: exit fullscreen when a click pauses browser playback ─────────────
; Only acts when already in fullscreen and browser was playing.
; Mirrors _HK_b: arms pendingExitFS so _EvalVideoHotkeys exits once audio stops.
; No direct _ExitFullscreenByUser() call — avoids races with the event path.
;
; Uses State.browserIsPlaying (which folds in the extension's own ground-truth
; extPlaying — see _UpdateMediaState) rather than the raw
; State.browserPlaybackStatus SMTC number. On Douyin that raw number can get
; stuck never reaching 4/Playing even while genuinely playing, which silently
; broke this check: the click would pause the video (the page's own native
; behavior) but pendingExitFS never armed, so fullscreen never exited.
~LButton:: {
    global State
    if !State.browserInFullScreen
        return
    if !State.browserIsPlaying
        return
    State.pendingExitFS := true
    SetTimer(_ClearPendingExitFS, -1000)
}

_ClearPendingExitFS() {
    global State
    State.pendingExitFS := false
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
