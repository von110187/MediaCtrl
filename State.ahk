; ============ GLOBAL STATE ============

global State := {
    ; session cache — populated once per tick, shared across monitors
    sessions:        [],
    currentInterval: 0,

    currentProgram: "",  ; active window process name

    ; ── Video (StateEngine.ahk) ─────────────────────────────────────────────
    page:     "",                    ; last "state" message from the extension ("" = none yet)
    rules:    Decide.New(),          ; Lib/Decide.ahk state (manual exit, miss ticks)
    machine:  FsMachine.New(),       ; Lib/FsMachine.ahk fullscreen state
    lossless: LosslessPolicy.New(),  ; Lib/LosslessPolicy.ahk on/off tracking
    losslessSentAt: 0,               ; TickCount of the last Lossless key we sent

    lastFsState:  "normal",  ; machine.state last acted on (clock, Lossless)
    pendingExit:  false,     ; b / video click while playing: exit once paused
    lastGaveUp:   "",        ; time of the last unconfirmed fullscreen request
    foregroundHwnd: 0,       ; last foreground window seen by the shell hook / tick
    chromeHwnd:     0,       ; last Chrome window that was foreground (its monitor)

    videoHotkeys: false,  ; gate for b w a s d right 0 1 2 3 4 5 e q esc f1 f2 f3

    monitorVideo: true,  ; F7 toggle

    songIsPlaying:        false,
    songSkipLock:         false,
    songSkipCooldownUntil: 0,   ; TickCount — outro skip suppressed until this time
    songLastUpdatedTime:  0,    ; previous LastUpdatedTime — track change detected on forward jump

    activeSpeaker: "",  ; set once at startup

    bassOn: false,

    gameRunning: Map(),  ; keyed as State.gameRunning["ZenlessZoneZero"]

    showTooltip: false,

    startupTime: A_TickCount,

    bridgeLog: [],  ; recent bridge messages, newest last — for debugging (tray → View → Variables)
}
