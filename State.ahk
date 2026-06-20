; ============ GLOBAL STATE ============

global State := {
    ; Session cache — populated once per tick, shared across monitors
    sessions:        [],
    currentInterval: 0,

    ; Active window (process name via WinGetProcessName)
    currentProgram: "",

    ; Current browser URL (pushed by extension via bridge)
    currentUrl: "",

    ; Next-episode href from <a class="cor5"> on the current page (or "")
    cor5Href: "",

    ; Playable tabs reported by extension (tabs with <video>/<audio>)
    playingTabs: [],

    ; Matched site config object (or "" if none)
    matchedSite: "",

    ; browser media state
    browserIsPlaying:        false,
    browserPlaybackStatus:   0,     ; last known PlaybackStatus for the browser session

    ; Debounce counter — how many consecutive ticks browser has reported not-playing.
    ; We only commit the state change after CHROME_STOP_DEBOUNCE ticks to avoid latency glitches.
    browserNotPlayingTicks: 0,
    browserInFullScreen: false,

    ; Set true by LButton/b while playing — exits fullscreen once audio stops
    pendingExitFS: false,
    ; while audio is still playing. Prevents auto re-enter until audio stops.
    manuallyExitedFS: false,

    ; Set true by F5 — blocks re-entry until audio stops (page reloading), then clears
    pendingF5: false,

    ; Video hotkeys gate — b w a s d 1 2 3 4 esc f1 f2 f3 f5
    videoHotkeys: false,

    ; monitorVideo toggle — F7 to enhance/pause monitoring
    monitorVideo: true,

    ; Bilibili first-visit sleep — tracks each playable tab URL seen, to sleep only on first enter
    startupDelaySeen: Map(),
    ; Consecutive-miss counter per startupDelaySeen entry — see pruning logic in StateEngine.ahk
    startupDelayMissCount: Map(),

    ; song
    songIsPlaying:        false,
    songSkipLock:         false,
    songSkipCooldownUntil: 0,   ; TickCount — outro skip suppressed until this time
    songLastUpdatedTime:  0,    ; previous LastUpdatedTime — track change detected when it jumps forward

    ; Speaker (set once at startup)
    activeSpeaker: "",

    ; Bass EQ
    bassOn: false,

    ; Game running state — keyed as State.gameRunning["ZenlessZoneZero"]
    gameRunning: Map(),

    ; Tooltip visibility
    showTooltip: false,

    ; Startup tick (for Adam D3V logic)
    startupTime: A_TickCount,
}
