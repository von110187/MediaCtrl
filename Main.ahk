#Requires AutoHotkey v2.0
#SingleInstance Force
#include Lib/Media.ahk
#include Config.ahk
#include State.ahk
#include StateEngine.ahk
#include Bridge.ahk
#include Speaker.ahk
#include Video.ahk
#include Audio.ahk
#include Hotkeys.ahk
#include UI.ahk

; ============ STARTUP ============

; Track speaker once at startup — we don't monitor changes mid-session
InitSpeaker()

; Deferred bridge start — avoids blocking hotkeys during npm/node startup
SetTimer(_DeferredBridgeStart, -100)
_DeferredBridgeStart() {
    StartBridgeServer()
}

; Register dynamic video hotkeys as Off — SetVideoHotkeys() controls them
InitVideoHotkeys()

; Fullscreen clock overlay — hidden until State.browserInFullScreen is true
InitClockOverlay()

; Register OS-level media events
RegisterMediaEvents()

; Seed initial state before first tick
try {
    sessions := Media.GetSessions()
    UpdateState(sessions)
} catch {
}

; Adaptive timer — tightens when media is active
State.currentInterval := CONFIG.TIMER_IDLE
SetTimer(MonitorTick, CONFIG.TIMER_IDLE)

; Lazy polling timers
SetTimer(MonitorGame,       2000)
SetTimer(ShowTooltip,       500)
SetTimer(UpdateClockOverlay, 1000)

; Adam D3V shutdown check — only fires once, 30 min after startup
if (State.activeSpeaker = "Adam D3V")
    SetTimer(_AdamShutdownCheck, -1800000)

OnExit(ExitHandler)
ExitHandler(reason, code) {
    shell := ComObject("WScript.Shell")
    shell.Run 'cmd /c taskkill /f /im node.exe /t', 0, false
}

; ============ MAIN TICK ============

MonitorTick() {
    global State
    try {
        sessions := Media.GetSessions()
    } catch as err {
        ; Media.GetSessions() is a COM/WinRT call, unrelated to the
        ; bridge-derived URL/tab state. A failure here used to `return`
        ; early and freeze tab/URL tracking along with it. Log and fall
        ; back to the last known session list so tracking keeps moving.
        try FileAppend(A_Now . " GetSessions failed: " . err.Message . "`n", A_Temp . "\ahk_getsessions_errors.log")
        sessions := State.sessions
    }
    UpdateState(sessions)
    try {
        MonitorAudio(sessions)
    } catch {
    }
}
