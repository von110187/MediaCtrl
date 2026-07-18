; ============ CONFIGURATION ============

global CONFIG := {
    TIMER_ACTIVE:    250,
    TIMER_IDLE:      1000,

    ; matched against SourceAppUserModelId / process name
    SONG:    "spotify",
    BROWSER: "chrome",

    ; win32 window class shared by all Chromium browsers
    BROWSER_WINDOW_CLASS: "Chrome_WidgetWin_1",

    ; native Spotify app — process name, used to activate (or launch) it
    ; when no SMTC session exists yet
    SONG_EXE: "Spotify.exe",

    ; consecutive not-playing ticks before treating the song browser as stopped
    BROWSER_STOP_DEBOUNCE: 1,

    ; consecutive ticks the URL must be missing from playingTabs before Gate 2
    ; treats the tab as left — absorbs brief <video> drops during feed re-renders
    ; (Douyin) without triggering a real exit-fullscreen keystroke
    URL_MISS_DEBOUNCE: 3,

    ; Lossless Scaling hotkey
    LOSSLESS_HOTKEY: "{F2}",

    ; ── Volume leveler ──────────────────────────────────────────────────────
    ; Attenuation-only (Windows per-app volume can't boost past original
    ; level) — quietly turns down loud videos to match the normal range
    ; rather than boosting quiet ones. TARGET/MIN tuned against observed
    ; Douyin/Bilibili peaks (normal ~0.1-0.3, occasional spikes ~0.5-0.7).
    VOLUME_LEVELER_ENABLED:   true,
    VOLUME_LEVELER_INTERVAL:  100,   ; ms between samples
    VOLUME_LEVELER_TARGET:    0.3,   ; target smoothed peak, 0.0-1.0
    VOLUME_LEVELER_DEADZONE:  0.01,  ; ignore error smaller than this
    VOLUME_LEVELER_SMOOTHING: 0.08,  ; EMA alpha
    VOLUME_LEVELER_STEP:      0.1,   ; max volume-multiplier change per sample
    VOLUME_LEVELER_MIN:       0.3,   ; never attenuate below this multiplier

    ; fsKey — fullscreen toggle key; mouseCenter — center mouse before entering FS;
    ; startupDelay/sleepMs — wait for player on first visit; holdSeek — hold Right
    ; to seek (Bilibili/Douyin style); iframePlayer — player is cross-origin, content
    ; script can't see into it
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
