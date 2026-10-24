#Requires AutoHotkey v2.0
#SingleInstance Force
#include Lib/Media.ahk
#include Lib/Decide.ahk
#include Lib/FsMachine.ahk
#include Lib/LosslessPolicy.ahk
#include Lib/LosslessDetect.ahk
#include Lib/Screen.ahk
#include Lib/Settings.ahk
#include Lib/Tone.ahk
#include Config.ahk
#include State.ahk
#include StateEngine.ahk
#include Bridge.ahk
#include BridgeClient.ahk
#include Speaker.ahk
#include Video.ahk
#include Wasapi.ahk
#include Audio.ahk
#include Hotkeys.ahk
#include UI.ahk

; ============ STARTUP ============

; PgUp/PgDn, Home/End, media keys — only the groups switched on in the
; settings. First, so they work the moment the script loads (the speaker
; setup below can wait for Peace, and the keep-awake tone takes a moment).
InitPersonalKeys()

; Track speaker once at startup — we don't monitor changes mid-session
InitSpeaker()
InitKeepAwake()  ; [speaker] keepAwake: a quiet tone so the speaker doesn't go to standby

; Deferred bridge start — avoids blocking hotkeys during npm/node startup
SetTimer(_DeferredBridgeStart, -100)
_DeferredBridgeStart() {
    Bridge_WriteExtensionToken()
    Bridge_Start()
    BridgeClient_Connect()  ; retries every 2 s until the bridge is listening
}

; Register the video hotkeys, all Off — _SetVideoHotkeys() turns them on/off
InitVideoHotkeys()

; Fullscreen clock overlay — hidden until the page reports fullscreen
InitClockOverlay()

; Seed initial state before first tick
try UpdateState(Media.GetSessions())

; Main tick: Spotify state and its silent-outro check (the video side has
; its own timer and the extension's reports)
SetTimer(MonitorTick, 1000)

; Page-tracked fullscreen and video keys (StateEngine.ahk)
VideoStart()

; Lazy polling timers
SetTimer(MonitorGame,       2000)
SetTimer(ShowTooltip,       500)
SetTimer(UpdateClockOverlay, 1000)

OnExit(ExitHandler)
ExitHandler(reason, code) {
    Bridge_KillAll()
}

; ============ MAIN TICK ============

MonitorTick() {
    global State
    try {
        sessions := Media.GetSessions()
    } catch as err {
        ; keep last known sessions so Spotify tracking doesn't freeze on a COM hiccup
        try FileAppend(A_Now . " GetSessions failed: " . err.Message . "`n", A_Temp . "\ahk_getsessions_errors.log")
        sessions := State.sessions
    }
    UpdateState(sessions)
    try {
        MonitorAudio(sessions)
    } catch {
    }
}
