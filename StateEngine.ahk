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
    } catch as err {
        ; Swallow COM errors during session churn — next tick recovers
    }
}

; ── Active program ────────────────────────────────────────────────────────────

_UpdateProgramState() {
    global State
    prog := VideoEnv.processName()
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

; ============ VIDEO ============

; Everything the video glue does outside the script — keys, bridge messages,
; the foreground window, time, timers, hotkeys, Lossless detection, the
; clock — goes through VideoEnv, so tests/TestVideoGlue.ahk can swap in a
; fake (no real keys, no Chrome, a fake clock). Called as VideoEnv.send(keys),
; so each function gets VideoEnv as its first parameter.
global VideoEnv := {
    now:            (*) => A_TickCount,
    foreground:     (*) => WinExist("A"),
    processName:    (*) => _ForegroundProcessName(),
    send:           (env, keys) => Send(keys),
    bridgeSend:     (env, msg) => BridgeClient_Send(msg),
    connected:      (*) => BridgeClient_Connected(),
    later:          (env, fn, ms) => SetTimer(fn, -ms),
    cancel:         (env, fn) => SetTimer(fn, 0),
    losslessActive: (*) => _LosslessActive(_ChromeMonitor()),
    clock:          (*) => UpdateClockVisibility(),
    setHotkeys:     (env, on) => _ApplyVideoHotkeys(on),
    notify:         (env, text) => (ToolTip(text, , , 2), SetTimer(() => ToolTip(, , , 2), -1200)),
    saveLevel:      (env, db) => IniWrite(db, VIDEO_SETTINGS_FILE, "leveler", "targetDb"),
}
VIDEO_SETTINGS_FILE := A_ScriptDir . "\mediactrl_settings.ini"

_ForegroundProcessName() {
    try return WinGetProcessName("A")
    return ""
}

VideoStart() {
    global CONFIG, State
    try State.levelDb := Number(IniRead(VIDEO_SETTINGS_FILE, "leveler", "targetDb"))
    SetTimer(_VideoTick, CONFIG.TICK_MS)

    ; foreground changes (incl. fullscreen apps) arrive at once, not on the next tick
    DllCall("RegisterShellHookWindow", "ptr", A_ScriptHwnd)
    OnMessage(DllCall("RegisterWindowMessage", "str", "SHELLHOOK", "uint"), _OnShellHook)
}

_VideoTick() {
    global State
    _CheckForeground()
    VideoEvaluate(true)
    _VideoRun(FsMachine.Timeout(State.machine, VideoEnv.now()))
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
    hwnd := VideoEnv.foreground()
    if hwnd = State.foregroundHwnd
        return
    State.foregroundHwnd := hwnd
    _UpdateProgramState()
    if _ChromeFocused() {
        State.chromeHwnd := hwnd
        VideoEnv.bridgeSend({type: "refresh"})
        _LosslessDetect()
        _LosslessApply(LosslessPolicy.OnChromeForeground(State.lossless))
    }
    VideoEvaluate(false)
}

; "Chrome is foreground" means the foreground window's process is chrome.exe
_ChromeFocused() {
    return VideoEnv.processName() = "chrome.exe"
}

; The monitor ({l, t, r, b}) the last foreground Chrome window is on — where
; its fullscreen video, the clock and the speed label are. Primary if unknown.
_ChromeMonitor() {
    global State
    monitors := []
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        monitors.Push({l: l, t: t, r: r, b: b})
    }
    index := MonitorGetPrimary()
    try {
        WinGetPos(&x, &y, &w, &h, "ahk_id " . State.chromeHwnd)
        index := Screen.MonitorOf({x: x, y: y, w: w, h: h}, monitors)
    }
    return monitors[index]
}

; every key we send lands in Chrome or nowhere
_SendToChrome(keys) {
    if _ChromeFocused()
        VideoEnv.send(keys)
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
        connected:       VideoEnv.connected() && IsObject(p),
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
        _VideoRun(FsMachine.Request(State.machine, "enter", VideoEnv.now(), _PageId()))
    if actions.exit
        _VideoRun(FsMachine.Request(State.machine, "exit", VideoEnv.now(), _PageId()))
}

_VideoRun(cmd) {
    global State, CONFIG
    switch cmd {
        case "nudge":
            VideoEnv.bridgeSend({type: "armFullscreen"})
        case "exitCmd":
            VideoEnv.bridgeSend({type: "exitFullscreen"})
        case "fsKey":
            ; only into the page the request was for, and never while typing
            site := _CurrentSite()
            p := State.page
            if site && p.pageId == State.machine.pageId && !p.editableFocused
                _SendToChrome(site.fsKey)
        case "gaveUp":
            State.lastGaveUp := FormatTime(, "HH:mm:ss")
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
    VideoEnv.clock()
    if fs == "fullscreen" || fs == "normal" {
        _LosslessDetect()
        _LosslessApply(LosslessPolicy.OnFullscreenChange(State.lossless, fs, _PageId(), _ChromeFocused(), adopted))
    }
}

; Feed the observed scaling state in (Lib/LosslessDetect.ahk) — but not right
; after we pressed the key: the overlay takes a moment to appear or go.
_LosslessDetect() {
    global State
    if VideoEnv.now() - State.losslessSentAt > 1500
        LosslessPolicy.SetDetected(State.lossless, VideoEnv.losslessActive())
}

_LosslessApply(action) {
    global State, CONFIG
    if action != "toggle"
        return
    State.losslessSentAt := VideoEnv.now()
    _SendToChrome(CONFIG.LOSSLESS_HOTKEY)
}

; user asked to leave fullscreen (Esc, b, click on the video): exit, and
; don't auto re-enter until playback stops
_VideoManualExit() {
    global State
    Decide.OnUnrequestedExit(State.rules, false, _PageId())
    _VideoRun(FsMachine.Request(State.machine, "exit", VideoEnv.now(), _PageId()))
}

_VideoCancelPendingExit() {
    global State
    State.pendingExit := false
    VideoEnv.cancel(_VideoPendingExitTimeout)
}

; b / click while playing: the site pauses first, then we exit. Sites that
; don't pause (or a Space that got eaten) still exit after CLICK_EXIT_WAIT_MS,
; so the flag can never linger and fire minutes later.
_VideoExitAfterPause() {
    global State, CONFIG
    _VideoCancelPendingExit()
    State.pendingExit := true
    VideoEnv.later(_VideoPendingExitTimeout, CONFIG.CLICK_EXIT_WAIT_MS)
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
        _VideoRun(FsMachine.Request(State.machine, "enter", VideoEnv.now(), _PageId()))
    }
}

; ── Messages from the extension ───────────────────────────────────────────────

_VideoOnState(msg) {
    global State
    pageChanged := IsObject(State.page) && msg.pageId !== State.page.pageId
    State.page := msg
    fresh := State.machine.lastReported == ""
    event := FsMachine.Report(State.machine, msg.isFullscreen, pageChanged, VideoEnv.now(), msg.pageId)
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
            _SendVideoConfig()
            VideoEvaluate(false)
        case "state":
            _VideoOnState(msg)
        case "armed":
            ; only for a real, current enter request on this page
            p := State.page
            if State.machine.state != "entering" || !p || msg.pageId !== p.pageId || msg.pageId !== State.machine.pageId
                return
            ; not from inside the socket callback
            VideoEnv.later(() => _SendToChrome("{F19}"), 1)
        case "enterFailed":
            _VideoRun(FsMachine.EnterFailed(State.machine, VideoEnv.now()))
        case "videoClick":
            ; the site's own click handler pauses the video; exit once that lands
            if State.machine.state == "fullscreen" && State.page && State.page.playing
                _VideoExitAfterPause()
    }
}

; The extension's settings: the sites, and the page leveler with the target
; the - / = keys set (Config.ahk's PAGE_LEVELER is left as the default)
_SendVideoConfig() {
    global CONFIG, State
    leveler := CONFIG.PAGE_LEVELER.Clone()
    leveler.targetDb := State.levelDb
    VideoEnv.bridgeSend({type: "config", sites: CONFIG.SITES, leveler: leveler})
}

; - / = : every video's loudness one step down / up (steps = -1 / +1)
VideoLevelStep(steps) {
    global CONFIG, State
    db := Max(CONFIG.LEVEL_MIN_DB, Min(CONFIG.LEVEL_MAX_DB, State.levelDb + steps * CONFIG.LEVEL_STEP_DB))
    if db != State.levelDb {
        State.levelDb := db
        VideoEnv.saveLevel(db)
        _SendVideoConfig()
    }
    limit := db == CONFIG.LEVEL_MAX_DB ? " (max)" : db == CONFIG.LEVEL_MIN_DB ? " (min)" : ""
    VideoEnv.notify("Video level: " . db . " dB" . limit)
}

; ── Public ────────────────────────────────────────────────────────────────────

VideoSetMonitor(on) {
    global State
    State.monitorVideo := on
    if !on && State.machine.state == "fullscreen"
        _VideoRun(FsMachine.Request(State.machine, "exit", VideoEnv.now(), _PageId()))
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
        connected:  VideoEnv.connected(),
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
