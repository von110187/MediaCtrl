#Requires AutoHotkey v2.0
#SingleInstance Force
#include Lib/Media.ahk
#include Lib/Decide.ahk
#include Lib/FsMachine.ahk
#include Lib/LosslessPolicy.ahk
#include Lib/LosslessDetect.ahk
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

; Track speaker once at startup — we don't monitor changes mid-session
InitSpeaker()

; Deferred bridge start — avoids blocking hotkeys during npm/node startup
SetTimer(_DeferredBridgeStart, -100)
_DeferredBridgeStart() {
    Bridge_WriteExtensionToken()
    Bridge_Start()
    BridgeClient_Connect()  ; retries every 2 s until the bridge is listening
}

; Register dynamic video hotkeys as Off — SetVideoHotkeys() controls them
InitVideoHotkeys()

; Fullscreen clock overlay — hidden until the page reports fullscreen
InitClockOverlay()

; Seed initial state before first tick
try {
    sessions := Media.GetSessions()
    UpdateState(sessions)
} catch {
}

; Adaptive timer — tightens when media is active
State.currentInterval := CONFIG.TIMER_IDLE
SetTimer(MonitorTick, CONFIG.TIMER_IDLE)

; Page-tracked fullscreen and video keys (StateEngine.ahk)
VideoStart()

; Lazy polling timers
SetTimer(MonitorGame,       2000)
SetTimer(ShowTooltip,       500)
SetTimer(UpdateClockOverlay, 1000)
SetTimer(_UpdateVolumeLeveler, CONFIG.VOLUME_LEVELER_INTERVAL)

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
        ; keep last known sessions so URL/tab tracking doesn't freeze on a COM hiccup
        try FileAppend(A_Now . " GetSessions failed: " . err.Message . "`n", A_Temp . "\ahk_getsessions_errors.log")
        sessions := State.sessions
    }
    UpdateState(sessions)
    try {
        MonitorAudio(sessions)
    } catch {
    }
}
