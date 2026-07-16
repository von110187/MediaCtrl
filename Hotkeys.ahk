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
        ; clear manual-exit flag so auto-fullscreen can re-trigger
        State.manuallyExitedFS := false
        _EvalVideoHotkeys()
    }
    if !State.showTooltip {
        ToolTip(State.monitorVideo ? "Monitor: On" : "Monitor: Off")
        SetTimer(() => ToolTip(), -1000)
    }
}

; ── F8: Exit fullscreen + trigger next-episode button ────────────────────────
F8:: {
    global State, CONFIG
    if State.browserInFullScreen
        _ExitFullscreenByUser()
    Sleep(300)

    if State.cor5Href != "" {
        ; cor5Href may be relative (e.g. /watch/...)
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
; AHK can't inspect the page DOM, so content.js reports the click target via
; WebSocket into ahk_video_click.txt — that report lands a little after this
; hotkey fires, hence the deferred check below. File is cleared immediately
; to drop any stale report from an earlier click.
;
; wasPlaying is snapshotted at click time, not re-read inside the deferred
; check: clicking the video is what pauses it, and on fast players (YouTube
; Shorts) that pause can land within the 200ms window, so a live re-read
; would race its own guard and swallow the exit.
~LButton:: {
    global State
    try FileDelete(A_Temp . "\ahk_video_click.txt")

    if !State.browserInFullScreen
        return
    if !State.browserIsPlaying
        return
    wasPlaying := State.browserIsPlaying
    SetTimer(() => _CheckVideoClickExit(wasPlaying), -200)
}

_CheckVideoClickExit(wasPlaying) {
    global State
    if !State.browserInFullScreen || !wasPlaying
        return
    try {
        if Trim(FileRead(A_Temp . "\ahk_video_click.txt")) = "1"
            _ExitFullscreenByUser()
    } catch {
        ; no report arrived — not a video click (or extension disconnected)
    }
}

; ── Ctrl+W: exit fullscreen state, then let browser close the tab ────────────
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
