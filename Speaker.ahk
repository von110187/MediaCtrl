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
        peace := SETTINGS.speaker.peacePath
        if !ProcessExist("Peace.exe") && peace != "" && FileExist(peace) {
            Run('"' . peace . '"')
            ProcessWait("Peace.exe", 10)
            Sleep(3000)
        }
        _SetBass(false)
    }
}

; Windows reports longer names like "Speakers (Harman Kardon Aura)", so this
; is a substring match — the one rule every Harman check uses. Off unless
; [speaker] harmanBass is on in mediactrl_settings.ini.
_IsHarmanSpeaker() {
    global State
    return SETTINGS.speaker.harmanBass && InStr(State.activeSpeaker, "Harman Kardon") > 0
}
