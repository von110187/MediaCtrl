; ============ CONFIGURATION ============

global CONFIG := {
    TIMER_ACTIVE:    250,
    TIMER_IDLE:      1000,

    ; App identifiers — change these if you switch music app or browser
    SONG:    "spotify",  ; matched against SourceAppUserModelId / process name
    BROWSER: "chrome",   ; matched against SourceAppUserModelId / process name

    ; win32 window class — shared by all Chromium-based browsers (Chrome,
    ; Edge, Brave, etc.) since they share the same rendering engine. Only
    ; needs changing if BROWSER above is switched to a non-Chromium browser.
    BROWSER_WINDOW_CLASS: "Chrome_WidgetWin_1",

    ; Window title of the song web app/PWA when installed as its own app
    ; window (used to activate it and send play/skip keys when no SMTC
    ; session exists yet — see _ActivateSongPWA in Audio.ahk).
    SONG_PWA_TITLE: "Spotify - Web Player",

    ; How many consecutive not-playing ticks before we treat the song browser as stopped.
    ; At TIMER_ACTIVE=250ms, 1 tick = 250ms debounce — fast response, still absorbs single glitches.
    BROWSER_STOP_DEBOUNCE: 1,

    ; How many consecutive ticks the current URL must be missing from playingTabs
    ; before Gate 2 (_EvalVideoHotkeys) treats the tab as actually left/not-playable.
    ; Needed because tag-detection sites (e.g. Douyin, which has no URL-based rule
    ; in content.js) can briefly drop their <video> element from the DOM during a
    ; feed/player re-render — a single missed tick shouldn't trigger a real
    ; exit-fullscreen keystroke, since a false exit can desync AHK's fullscreen
    ; state from the page's real state until the page is reloaded.
    URL_MISS_DEBOUNCE: 3,

    ; Lossless Scaling hotkey
    LOSSLESS_HOTKEY: "{F2}",

    ; ── Volume leveler ──────────────────────────────────────────────────────
    ; Reactively attenuates Chrome's per-app volume to smooth out videos that
    ; are recorded louder/quieter than each other. This is attenuation-only —
    ; Windows' per-app volume can turn a session down but can never boost it
    ; past its original level, so this evens things out by quietly turning
    ; down the loud ones, not by boosting the quiet ones.
    ;
    ; Tuned against observed Douyin/Bilibili peaks: most videos read ~0.1-0.3,
    ; occasional ones spike to ~0.5-0.7. TARGET sits inside the normal 0.1-0.3
    ; band (not above it) so loud outliers get pulled down to match what
    ; "normal" actually sounds like, rather than just capped at some level
    ; that's still louder than everything else.
    VOLUME_LEVELER_ENABLED:   true,
    VOLUME_LEVELER_INTERVAL:  200,   ; ms between samples — lower = more samples/sec = faster convergence
    VOLUME_LEVELER_TARGET:    0.3,   ; target smoothed peak, 0.0–1.0 — center of the normal 0.1-0.3 range
    VOLUME_LEVELER_DEADZONE:  0.02,  ; ignore error smaller than this — quiet/loud clusters are well separated, so this can be tight
    VOLUME_LEVELER_SMOOTHING: 0.6,  ; EMA alpha — higher = reacts to current loudness faster, less lag behind the actual video
    VOLUME_LEVELER_STEP:      0.3,  ; max volume-multiplier change per sample — higher = snaps to the right level faster
    VOLUME_LEVELER_MIN:       0.35,  ; never attenuate below this multiplier — extra headroom now that target is lower

    ; Playable media sites matched against State.currentUrl
    ; fsKey       — key to toggle fullscreen for this site
    ; mouseCenter — move mouse to centre before entering fullscreen
    ; startupDelay — wait for player on first visit (sleepMs controls duration)
    ; sleepMs     — startup delay in ms (used when startupDelay is true)
    ; holdSeek    — hold Right key for seek (Bilibili/Douyin style)
    ; iframePlayer — player lives in a cross-origin iframe the content script can't see into
    SITES: {
        youtube:  { url: "youtube.com",  fsKey: "f", mouseCenter: false, startupDelay: true,  sleepMs: 100,  holdSeek: false, iframePlayer: false },
        bilibili: { url: "bilibili.com", fsKey: "f", mouseCenter: false, startupDelay: true,  sleepMs: 1500, holdSeek: true,  iframePlayer: false },
        douyin:   { url: "douyin.com",   fsKey: "h", mouseCenter: false, startupDelay: true,  sleepMs: 1000, holdSeek: true,  iframePlayer: false },
        anime:    { url: "cycani.org",   fsKey: "f", mouseCenter: true,  startupDelay: false, sleepMs: 0,    holdSeek: false, iframePlayer: true },
    },

    ; Game process names (without .exe)
    GAME_LIST: ["ZenlessZoneZero"],
}

global WASAPI_CLSIDS := {
    MMDeviceEnumerator: "{BCDE0395-E52F-467C-8E3D-C4579291692E}",
    IMMDeviceEnumerator: "{A95664D2-9614-4F35-A746-DE8DB63617E6}",
    IAudioSessionManager2: "{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}",
    IAudioSessionControl2: "{bfb7ff88-7239-4fc9-8fa2-07c950be9c6d}",
    IAudioMeterInformation: "{C02216F6-8C67-4B5B-9D00-D008E73E0064}",
    IAudioEndpointVolume: "{5CDF2C82-841E-4546-9722-0CF74078229A}",
    ISimpleAudioVolume: "{87CE5498-68D6-44E5-9215-6DA47EF883D8}"
}
