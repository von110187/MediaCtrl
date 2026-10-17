; ============ CONFIGURATION ============

global CONFIG := {
    TIMER_ACTIVE:    250,
    TIMER_IDLE:      1000,

    ; matched against SourceAppUserModelId / process name
    SONG:    "spotify",
    BROWSER: "chrome",

    ; native Spotify app — process name, used to activate (or launch) it
    ; when no SMTC session exists yet
    SONG_EXE: "Spotify.exe",

    ; explicit fallback path used only if the "App Paths" registry lookup
    ; (see _LaunchSongApp in Audio.ahk) and bare-name Run() both fail —
    ; e.g. a portable/manual install with no registry entry.
    SONG_EXE_PATH: "C:\Users\87\AppData\Roaming\Spotify\Spotify.exe",

    ; Lossless Scaling hotkey — toggles scaling for the foreground window, so
    ; it's only ever sent while Chrome is foreground
    LOSSLESS_HOTKEY: "{F1}",

    ; bridge/bridge.js WebSocket port (127.0.0.1 only)
    BRIDGE_PORT: 9224,

    ; ── Volume leveler ──────────────────────────────────────────────────────
    ; Attenuation-only (Windows per-app volume can't boost past original
    ; level) — quietly turns down loud videos to match the normal range
    ; rather than boosting quiet ones. TARGET/MIN tuned against observed
    ; Douyin/Bilibili peaks (normal ~0.1-0.3, occasional spikes ~0.5-0.7).
    VOLUME_LEVELER_ENABLED:   true,
    VOLUME_LEVELER_INTERVAL:  100,   ; ms between samples
    VOLUME_LEVELER_TARGET:    0.35,   ; target smoothed peak, 0.0-1.0
    VOLUME_LEVELER_DEADZONE:  0.01,  ; ignore error smaller than this
    VOLUME_LEVELER_SMOOTHING: 0.08,  ; EMA alpha
    VOLUME_LEVELER_STEP:      0.1,   ; max volume-multiplier change per sample
    VOLUME_LEVELER_MIN:       0.3,   ; never attenuate below this multiplier

    ; ── Video sites ─────────────────────────────────────────────────────────
    ; Sent to the Chrome extension on connect (config message), so this is the
    ; only place site settings live.
    ; match — domain (and its subdomains); fsButton — the site's own fullscreen
    ; button, clicked during the F19 nudge; playerSelector — the real player
    ; container (requestFullscreen fallback, and how hover previews are told
    ; apart from the real video); fsKey — last-resort key
    ; Douyin: no playerSelector — its feed mounts several players, so the
    ; active video is found by which one is actually playing. Its other button,
    ; .xgplayer-page-full-screen, is window-only "web fullscreen" that the
    ; browser doesn't report, so it isn't used.
    SITES: {
        youtube:  { match: "youtube.com",  fsButton: ".ytp-fullscreen-button", playerSelector: "#movie_player",         fsKey: "f" },
        bilibili: { match: "bilibili.com", fsButton: ".bpx-player-ctrl-full",  playerSelector: ".bpx-player-container", fsKey: "f" },
        douyin:   { match: "douyin.com",   fsButton: ".xgplayer-fullscreen",   playerSelector: "",                      fsKey: "h" },
    },

    TICK_MS:            250,    ; video evaluation timer
    SEEK_SECONDS:       87,     ; e / q jump size
    SPEEDS:             [1.0, 1.5, 2.0, 3.0],  ; keys 1 2 3 4
    HOLD_SPEED:         2.0,    ; d / Right held: play at this rate until released
    HOLD_TAP_MS:        300,    ; released sooner than this: a tap, sent as one Right
    CLICK_EXIT_WAIT_MS: 500,    ; b / video click: exit after the site's pause, at most this long

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
