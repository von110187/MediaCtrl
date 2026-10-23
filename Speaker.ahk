; ============ SPEAKER ============
; Speaker is detected ONCE at startup — we don't monitor mid-session changes.
; Harman Kardon: bass is on while one of the games is running, off otherwise.

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

; ── Keep-awake ────────────────────────────────────────────────────────────────
; Speakers like the SoundSticks 4 go to standby after ~10 min without audio
; (or with very low audio), and can't be told not to. With [speaker] keepAwake
; on, a short tone plays every keepAwakeMinutes while nothing else is playing,
; so the speaker keeps seeing a signal. Default 19 kHz at -20 dB: above what
; most adults hear, but at full strength for the speaker's signal detection.
; (20 Hz, also inaudible, was too weak — low tones get filtered out on the way.)

KEEP_AWAKE_WAV := A_Temp . "\mediactrl_keepawake.wav"

InitKeepAwake() {
    s := SETTINGS.speaker
    if !s.keepAwake
        return
    try Tone.WriteWav(KEEP_AWAKE_WAV, s.keepAwakeHz, s.keepAwakeDb, 2)
    catch
        return
    SetTimer(_KeepAwakeTick, Max(1, s.keepAwakeMinutes) * 60000)
}

_KeepAwakeTick() {
    ; something audible is already playing: the speaker is awake, and the tone
    ; shouldn't mix into it (e.g. a game with the bass boost on)
    if Wasapi_MaxPeak("") > 0.001
        return
    ; PlaySound rather than SoundPlay: SoundPlay goes through MCI, which fails
    ; on long paths. SND_FILENAME | SND_ASYNC | SND_NODEFAULT
    DllCall("winmm\PlaySoundW", "str", KEEP_AWAKE_WAV, "ptr", 0, "uint", 0x20003)
}

; Windows reports longer names like "Speakers (Harman Kardon Aura)", so this
; is a substring match — the one rule every Harman check uses. Off unless
; [speaker] harmanBass is on in mediactrl_settings.ini.
_IsHarmanSpeaker() {
    global State
    return SETTINGS.speaker.harmanBass && InStr(State.activeSpeaker, "Harman Kardon") > 0
}
