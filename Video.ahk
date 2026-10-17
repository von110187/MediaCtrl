; ============ MONITOR GAME ============

MonitorGame() {
    global State, CONFIG

    for game in CONFIG.GAME_LIST {
        exeName    := game . ".exe"
        isRunning  := ProcessExist(exeName) ? true : false
        wasRunning := State.gameRunning.Has(game) ? State.gameRunning[game] : false

        if isRunning = wasRunning
            continue

        State.gameRunning[game] := isRunning

        ; Update bass on game open/close
        if _IsHarmanSpeaker()
            _UpdateHarmanBass()
    }
}

; ============ MONITOR LM STUDIO ============
; Kills LosslessScaling when LM Studio is running (GPU conflict).

MonitorLMStudio() {
    if ProcessExist("LM Studio.exe") {
        if ProcessExist("LosslessScaling.exe")
            ProcessClose("LosslessScaling.exe")
        return
    }
    if !ProcessExist("LosslessScaling.exe") {
        Run('"C:\Program Files (x86)\Steam\steamapps\common\Lossless Scaling\LosslessScaling.exe"')
        WinWait("ahk_exe LosslessScaling.exe")
        WinClose("ahk_exe LosslessScaling.exe")
    }
}

; ============ VIDEO HOTKEYS — dynamic registration ============
; All video keys default OFF. _SetVideoHotkeys() turns them on/off together,
; as Lib/Decide.ahk says (StateEngine.ahk VideoEvaluate). Keys that reach the
; page go through _SendToChrome; seek/speed go to the page via the extension.

VIDEO_KEYS := Map(
    "$b",   _HK_b,     ; exit fullscreen (pausing first if playing) / enter
    "$w",   _HK_w,     ; w a s d — arrow keys
    "$a",   _HK_a,
    "$s",   _HK_s,
    "$d",   _HK_HoldSpeed,  ; d / Right — tap: Right; hold: CONFIG.HOLD_SPEED
    "$Right", _HK_HoldSpeed,
    "$0",   _HK_0,     ; restart from the beginning
    "$1",   _HK_Speed, ; 1 2 3 4 5 — playback speed (CONFIG.SPEEDS)
    "$2",   _HK_Speed,
    "$3",   _HK_Speed,
    "$4",   _HK_Speed,
    "$5",   _HK_Speed,
    "$e",   _HK_e,     ; e / q — skip ±CONFIG.SEEK_SECONDS
    "$q",   _HK_q,
    "$Esc", _HK_Esc,   ; toggle fullscreen
    "$F1",  _HK_Lossless,  ; F1 F2 F3 — Lossless Scaling passthrough
    "$F2",  _HK_Lossless,
    "$F3",  _HK_Lossless,
)

InitVideoHotkeys() {
    global VIDEO_KEYS
    for key, handler in VIDEO_KEYS
        Hotkey(key, handler, "Off")
}

_SetVideoHotkeys(enable) {
    global State, VIDEO_KEYS
    if State.videoHotkeys = enable
        return
    State.videoHotkeys := enable
    for key in VIDEO_KEYS
        Hotkey(key, enable ? "On" : "Off")
}

; ── Video hotkey handlers ─────────────────────────────────────────────────────

_HK_b(*) {
    global State
    if State.machine.state != "fullscreen" {
        _VideoToggleFullscreen()
    } else if State.page && State.page.playing {
        _SendToChrome("{Space}")
        _VideoExitAfterPause()
    } else {
        _VideoManualExit()
    }
}

_HK_w(*) => _SendToChrome("{Up}")
_HK_a(*) => _SendToChrome("{Left}")
_HK_s(*) => _SendToChrome("{Down}")

; d / Right: a tap sends one Right (the site's own seek); held, the video
; plays at CONFIG.HOLD_SPEED until released, on every site (YouTube has no
; hold-to-speed of its own). The extension sets the rate and restores the
; previous one; auto-repeat is swallowed while the key is held.
_HK_HoldSpeed(hk) {
    global CONFIG
    key := SubStr(hk, 2)
    if KeyWait(key, "T" . CONFIG.HOLD_TAP_MS / 1000) {
        _SendToChrome("{Right}")
        return
    }
    BridgeClient_Send({type: "holdSpeed", on: true, rate: CONFIG.HOLD_SPEED})
    KeyWait(key)
    BridgeClient_Send({type: "holdSpeed", on: false})
}

_HK_0(*) => BridgeClient_Send({type: "seek", to: 0})
_HK_e(*) => BridgeClient_Send({type: "seek", by: CONFIG.SEEK_SECONDS})
_HK_q(*) => BridgeClient_Send({type: "seek", by: -CONFIG.SEEK_SECONDS})

_HK_Speed(hk) {
    global CONFIG
    BridgeClient_Send({type: "speed", rate: CONFIG.SPEEDS[Integer(SubStr(hk, 2))]})
}

_HK_Esc(*) => _VideoToggleFullscreen()

; A manual press during a fullscreen video hands Lossless Scaling for that
; page to the user (Lib/LosslessPolicy.ahk).
_HK_Lossless(*) {
    global State, CONFIG
    if !_ChromeFocused()
        return
    LosslessPolicy.OnManualPress(State.lossless, State.machine.state, _PageId())
    State.losslessSentAt := A_TickCount
    Send(CONFIG.LOSSLESS_HOTKEY)
}
