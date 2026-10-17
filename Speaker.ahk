; ============ SPEAKER ============
; Speaker is detected ONCE at startup — we don't monitor mid-session changes.
; Harman Kardon: bass follows game state (on when in game, off otherwise).

InitSpeaker() {
    global State, CONFIG

    try {
        speakerName := SoundGetName()
    } catch {
        speakerName := ""
    }

    State.activeSpeaker := speakerName

    if _IsHarmanSpeaker() {
        ; Default bass OFF
        ; Peace EQ should be running already — launch if not
        if !ProcessExist("Peace.exe") {
            Run('"C:\Program Files\EqualizerAPO\config\Peace.exe"')
            ProcessWait("Peace.exe")
            Sleep(3000)
        }
        _SetBass(false)
    }
}

; Windows reports longer names like "Speakers (Harman Kardon Aura)", so this
; is a substring match — the one rule every Harman check uses.
_IsHarmanSpeaker() {
    global State
    return InStr(State.activeSpeaker, "Harman Kardon") > 0
}
