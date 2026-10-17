; ============ STATE ENGINE ============
; Program/Spotify state from the main tick, and the video glue: the
; extension's page reports (via BridgeClient.ahk) feed the pure rules
; (Lib/Decide.ahk), the fullscreen state machine (Lib/FsMachine.ahk) and the
; Lossless Scaling policy (Lib/LosslessPolicy.ahk); this file carries out what
; they decide. Port of reference/hammerspoon/video.lua.

UpdateState(sessions) {
    global State
    State.sessions := sessions

    try {
        _UpdateProgramState()
        _UpdateSongState(sessions)
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
    if _IsHarmanSpeaker()
        _UpdateHarmanBass()

    VideoEvaluate(false)
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

; ── Spotify session state ─────────────────────────────────────────────────────
; Browser playback comes from the extension (State.page.playing), not SMTC.

_UpdateSongState(sessions) {
    global State, CONFIG
    playing := false
    for session in sessions {
        if InStr(session.SourceAppUserModelId, CONFIG.SONG)
            playing := session.PlaybackStatus = 4
    }
    State.songIsPlaying := playing
}

; ── Adaptive timer ────────────────────────────────────────────────────────────
; Tightens the main tick (Spotify outro check) while anything is playing.

_UpdateAdaptiveTimer() {
    global State, CONFIG

    anyActive := State.songIsPlaying || (State.page && State.page.playing)
    if !anyActive {
        for session in State.sessions {
            if session.PlaybackStatus = 4 {
                anyActive := true
                break
            }
        }
    }

    interval := anyActive ? CONFIG.TIMER_ACTIVE : CONFIG.TIMER_IDLE
    if State.currentInterval != interval {
        State.currentInterval := interval
        SetTimer(MonitorTick, interval)
    }
}

; ============ VIDEO ============

VideoStart() {
    global CONFIG
    SetTimer(_VideoTick, CONFIG.TICK_MS)

    ; foreground changes (incl. fullscreen apps) arrive at once, not on the next tick
    DllCall("RegisterShellHookWindow", "ptr", A_ScriptHwnd)
    OnMessage(DllCall("RegisterWindowMessage", "str", "SHELLHOOK", "uint"), _OnShellHook)
}

_VideoTick() {
    global State
    _CheckForeground()
    VideoEvaluate(true)
    _VideoRun(FsMachine.Timeout(State.machine, A_TickCount))
}

_OnShellHook(wParam, lParam, *) {
    if (wParam & 0x7FFF) = 4  ; HSHELL_WINDOWACTIVATED / HSHELL_RUDEAPPACTIVATED
        SetTimer(_CheckForeground, -1)
}

; A Chrome window came to the front: have the extension report that window's
; active tab (Chrome's own focus event isn't reliable), and apply a Lossless
; change that was held back while Chrome wasn't foreground.
_CheckForeground() {
    global State
    hwnd := WinExist("A")
    if hwnd = State.foregroundHwnd
        return
    State.foregroundHwnd := hwnd
    _UpdateProgramState()
    if _ChromeFocused() {
        BridgeClient_Send({type: "refresh"})
        _LosslessDetect()
        _LosslessApply(LosslessPolicy.OnChromeForeground(State.lossless))
    }
    VideoEvaluate(false)
}

; "Chrome is foreground" means the foreground window's process is chrome.exe
_ChromeFocused() {
    try return WinGetProcessName("A") = "chrome.exe"
    return false
}

; every key we send lands in Chrome or nowhere
_SendToChrome(keys) {
    if _ChromeFocused()
        Send(keys)
}

_CurrentSite() {
    global State, CONFIG
    name := State.page ? State.page.site : ""
    if name == "" || !CONFIG.SITES.HasOwnProp(name)
        return ""
    return CONFIG.SITES.%name%
}

_PageId() {
    global State
    return State.page ? State.page.pageId : ""
}

_VideoInputs() {
    global State
    p := State.page
    return {
        connected:       BridgeClient_Connected() && IsObject(p),
        monitorOn:       State.monitorVideo,
        chromeFocused:   _ChromeFocused(),
        site:            p ? p.site : "",
        playable:        p ? p.playable : false,
        playing:         p ? p.playing : false,
        ready:           p ? p.ready : false,
        editableFocused: p ? p.editableFocused : false,
        pageId:          p ? p.pageId : "",
        fs:              State.machine.state,
    }
}

VideoEvaluate(isTick) {
    global State
    actions := Decide.Evaluate(State.rules, _VideoInputs(), isTick)
    _SetVideoHotkeys(actions.keys)
    if actions.enter
        _VideoRun(FsMachine.Request(State.machine, "enter", A_TickCount, _PageId()))
    if actions.exit
        _VideoRun(FsMachine.Request(State.machine, "exit", A_TickCount, _PageId()))
}

_VideoRun(cmd) {
    global State, CONFIG
    switch cmd {
        case "nudge":
            BridgeClient_Send({type: "armFullscreen"})
        case "exitCmd":
            BridgeClient_Send({type: "exitFullscreen"})
        case "fsKey":
            ; only into the page the request was for, and never while typing
            site := _CurrentSite()
            p := State.page
            if site && p.pageId == State.machine.pageId && !p.editableFocused
                _SendToChrome(site.fsKey)
        case "gaveUp":
            State.lastGaveUp := FormatTime(, "HH:mm:ss")
            _BridgeLogAdd("gaveUp", "no fullscreen confirmation")
    }
    _NotifyFullscreen()
}

; The machine settled somewhere new: clock and Lossless Scaling follow it.
; adopted: the first report after an AHK reload put it there.
_NotifyFullscreen(adopted := false) {
    global State
    fs := State.machine.state
    if fs == State.lastFsState
        return
    State.lastFsState := fs
    UpdateClockVisibility()
    if fs == "fullscreen" || fs == "normal" {
        _LosslessDetect()
        _LosslessApply(LosslessPolicy.OnFullscreenChange(State.lossless, fs, _PageId(), _ChromeFocused(), adopted))
    }
}

; Feed the observed scaling state in (Lib/LosslessDetect.ahk) — but not right
; after we pressed the key: the overlay takes a moment to appear or go.
_LosslessDetect() {
    global State
    if A_TickCount - State.losslessSentAt > 1500
        LosslessPolicy.SetDetected(State.lossless, _LosslessActive())
}

_LosslessApply(action) {
    global State, CONFIG
    if action != "toggle"
        return
    State.losslessSentAt := A_TickCount
    _SendToChrome(CONFIG.LOSSLESS_HOTKEY)
}

; user asked to leave fullscreen (Esc, b, click on the video): exit, and
; don't auto re-enter until playback stops
_VideoManualExit() {
    global State
    Decide.OnUnrequestedExit(State.rules, false, _PageId())
    _VideoRun(FsMachine.Request(State.machine, "exit", A_TickCount, _PageId()))
}

_VideoCancelPendingExit() {
    global State
    State.pendingExit := false
    SetTimer(_VideoPendingExitTimeout, 0)
}

; b / click while playing: the site pauses first, then we exit. Sites that
; don't pause (or a Space that got eaten) still exit after CLICK_EXIT_WAIT_MS,
; so the flag can never linger and fire minutes later.
_VideoExitAfterPause() {
    global State, CONFIG
    _VideoCancelPendingExit()
    State.pendingExit := true
    SetTimer(_VideoPendingExitTimeout, -CONFIG.CLICK_EXIT_WAIT_MS)
}

_VideoPendingExitTimeout() {
    global State
    if State.pendingExit {
        State.pendingExit := false
        _VideoManualExit()
    }
}

_VideoToggleFullscreen() {
    global State
    if State.machine.state == "fullscreen" {
        _VideoManualExit()
    } else if State.machine.state == "normal" {
        State.rules.manualExit := false
        _VideoRun(FsMachine.Request(State.machine, "enter", A_TickCount, _PageId()))
    }
}

; ── Messages from the extension ───────────────────────────────────────────────

_VideoOnState(msg) {
    global State
    pageChanged := IsObject(State.page) && msg.pageId !== State.page.pageId
    State.page := msg
    fresh := State.machine.lastReported == ""
    event := FsMachine.Report(State.machine, msg.isFullscreen, pageChanged, A_TickCount, msg.pageId)
    if event == "unrequestedExit"
        Decide.OnUnrequestedExit(State.rules, pageChanged, msg.pageId)
    _NotifyFullscreen(fresh)

    if pageChanged {
        _VideoCancelPendingExit()
    } else if State.pendingExit && !msg.playing {
        _VideoCancelPendingExit()
        _VideoManualExit()
    }
    VideoEvaluate(false)
}

; Called by BridgeClient.ahk for every message from the bridge.
OnBridgeMessage(msg) {
    global State, CONFIG
    switch msg.type {
        case "pong":
            return
        case "extConnected":
            ; (re)connected to the bridge, or the extension came or went
            BridgeClient_Send({type: "config", sites: CONFIG.SITES})
            _BridgeLogAdd(msg.type, msg.connected ? "yes" : "no")
            VideoEvaluate(false)
        case "state":
            _BridgeLogAdd(msg.type, msg.site . (msg.playing ? " ▶" : "") . (msg.isFullscreen ? " fs" : "") . (msg.editableFocused ? " typing" : ""))
            _VideoOnState(msg)
        case "armed":
            _BridgeLogAdd(msg.type)
            ; only for a real, current enter request on this page
            p := State.page
            if State.machine.state != "entering" || !p || msg.pageId !== p.pageId || msg.pageId !== State.machine.pageId
                return
            ; not from inside the socket callback
            SetTimer(() => _SendToChrome("{F19}"), -1)
        case "enterFailed":
            _BridgeLogAdd(msg.type)
            _VideoRun(FsMachine.EnterFailed(State.machine, A_TickCount))
        case "videoClick":
            _BridgeLogAdd(msg.type)
            ; the site's own click handler pauses the video; exit once that lands
            if State.machine.state == "fullscreen" && State.page && State.page.playing
                _VideoExitAfterPause()
        case "log":
            _BridgeLogAdd(msg.type, msg.HasOwnProp("text") ? msg.text : "")
        default:
            _BridgeLogAdd(msg.type)
    }
}

_BridgeLogAdd(type, detail := "") {
    global State
    State.bridgeLog.Push(FormatTime(, "HH:mm:ss") . "  " . type . (detail != "" ? "  " . SubStr(detail, 1, 50) : ""))
    if State.bridgeLog.Length > 30
        State.bridgeLog.RemoveAt(1)
}

; ── Public ────────────────────────────────────────────────────────────────────

VideoSetMonitor(on) {
    global State
    State.monitorVideo := on
    if !on && State.machine.state == "fullscreen"
        _VideoRun(FsMachine.Request(State.machine, "exit", A_TickCount, _PageId()))
    VideoEvaluate(false)
}

VideoStatus() {
    global State
    return {
        page:       State.page,
        fs:         State.machine.state,
        manualExit: State.rules.manualExit,
        keysOn:     State.videoHotkeys,
        monitorOn:  State.monitorVideo,
        connected:  BridgeClient_Connected(),
        lastGaveUp: State.lastGaveUp,
        lossless:   State.lossless,
    }
}

; ── Bass helpers ──────────────────────────────────────────────────────────────

_SetBass(enable) {
    global State
    if State.bassOn = enable
        return
    State.bassOn := enable
    Send(enable ? "^!{F12}" : "^!{F11}")
}
