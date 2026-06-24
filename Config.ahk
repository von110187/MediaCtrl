; ============ CONFIGURATION ============

global CONFIG := {
    TIMER_ACTIVE:    250,
    TIMER_IDLE:      1000,

    ; App identifiers — change these if you switch music app or browser
    SONG:    "spotify",  ; matched against SourceAppUserModelId / process name
    BROWSER: "chrome",   ; matched against SourceAppUserModelId / process name

    ; How many consecutive not-playing ticks before we treat the song browser as stopped.
    ; At TIMER_ACTIVE=250ms, 1 tick = 250ms debounce — fast response, still absorbs single glitches.
    CHROME_STOP_DEBOUNCE: 1,

    ; Lossless Scaling hotkey
    LOSSLESS_HOTKEY: "{F2}",

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
        douyin:   { url: "douyin.com",   fsKey: "h", mouseCenter: false, startupDelay: false, sleepMs: 0,    holdSeek: true,  iframePlayer: false },
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
    IAudioEndpointVolume: "{5CDF2C82-841E-4546-9722-0CF74078229A}"
}
