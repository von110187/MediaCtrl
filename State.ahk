; ============ GLOBAL STATE ============

global State := {
    ; session cache — populated once per tick, shared across monitors
    sessions:        [],
    currentInterval: 0,

    currentProgram: "",  ; active window process name
    currentUrl: "",       ; current browser URL, pushed by extension via bridge
    cor5Href: "",          ; next-episode href from <a class="cor5"> (or "")
    playingTabs: [],        ; playable tabs reported by extension
    matchedSite: "",         ; matched site config object (or "")

    browserIsPlaying:      false,
    browserPlaybackStatus: 0,      ; last known PlaybackStatus for the browser session

    ; debounce — consecutive not-playing ticks before committing the change (see BROWSER_STOP_DEBOUNCE)
    browserNotPlayingTicks: 0,
    browserInFullScreen: false,

    ; debounce — consecutive Gate 2 misses (see URL_MISS_DEBOUNCE in Config.ahk)
    urlNotPlayableTicks: 0,

    ; ground-truth "is the video playing" observed directly by content.js,
    ; bypassing SMTC (see StateEngine.ahk _UpdateMediaState)
    extPlaying: false,

    ; volume leveler — see Audio.ahk _UpdateVolumeLeveler / Config.ahk
    volumeSmoothedPeak: 0.0,
    volumeMultiplier:   1.0,
    volumeDebug:        "",  ; last _SetBrowserVolume() diagnostic, for the F6 tooltip

    pendingExitFS: false,     ; set by LButton/b while playing — exits once audio stops
    manuallyExitedFS: false,  ; user exited FS manually — blocks auto re-enter until audio stops

    pendingF5: false,  ; set by F5 — blocks re-entry until page reload finishes, then clears

    videoHotkeys: false,  ; gate for b w a s d 1 2 3 4 esc f1 f2 f3 f5

    monitorVideo: true,  ; F7 toggle

    ; Bilibili first-visit sleep — tracks each playable tab URL seen
    startupDelaySeen: Map(),
    ; consecutive-miss counter per startupDelaySeen entry — see pruning in StateEngine.ahk
    startupDelayMissCount: Map(),

    songIsPlaying:        false,
    songSkipLock:         false,
    songSkipCooldownUntil: 0,   ; TickCount — outro skip suppressed until this time
    songLastUpdatedTime:  0,    ; previous LastUpdatedTime — track change detected on forward jump

    activeSpeaker: "",  ; set once at startup

    bassOn: false,

    gameRunning: Map(),  ; keyed as State.gameRunning["ZenlessZoneZero"]

    showTooltip: false,

    startupTime: A_TickCount,
}
