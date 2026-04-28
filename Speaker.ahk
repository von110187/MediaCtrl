; ============ SPEAKER ============
; Speaker is detected ONCE at startup — we don't monitor mid-session changes.
; Harman Kardon: bass follows game state (on when in game, off otherwise).
; Adam D3V:      first 30 min do nothing; after 30 min check if still present,
;                if gone → shutdown PC (lazy single-shot timer, not polling).

InitSpeaker() {
    global State, CONFIG

    try {
        speakerName := SoundGetName()
    } catch {
        speakerName := ""
    }

    State.activeSpeaker := speakerName

    if (speakerName = "Harman Kardon") {
        ; Default bass OFF
        _SetBass(false)
        ; Peace EQ should be running already — launch if not
        if !ProcessExist("Peace.exe") {
            Run('"D:\Program Files\EqualizerAPO\config\Peace.exe"')
            ProcessWait("Peace.exe")
            Sleep(3000)
        }

    } else if (speakerName = "Adam D3V") {
        ; Nothing for first 30 min — timer set in Main.ahk after InitSpeaker()
    }
}

; Called once, 30 minutes after startup, only when Adam D3V is the speaker.
_AdamShutdownCheck() {
    global State
    try {
        name := SoundGetName()
    } catch {
        name := ""
    }
    if (name != "Adam D3V")
        Run("shutdown.exe /s /f /t 0")
}
