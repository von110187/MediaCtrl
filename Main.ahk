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
SetTimer(MonitorGame,    2000)
SetTimer(ShowTooltip,    500)

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
        ; Media.GetSessions() is a COM/WinRT call into the OS media-session
        ; manager — unrelated to the bridge-derived URL/tab state, which
        ; comes from files written by the Chrome extension. Previously a
        ; failure here did `return`, skipping UpdateState() (and therefore
        ; _UpdateUrlState()) entirely for the tick — so a single COM hiccup
        ; (e.g. triggered by a new tab creating a new OS media session)
        ; could freeze the playable-tabs list right along with it, with no
        ; visibility into why. Log it and fall back to the last known
        ; session list instead, so tab/URL tracking keeps moving regardless.
        try FileAppend(A_Now . " GetSessions failed: " . err.Message . "`n", A_Temp . "\ahk_getsessions_errors.log")
        sessions := State.sessions
    }
    UpdateState(sessions)
    try {
        MonitorAudio(sessions)
    } catch {
    }
}
