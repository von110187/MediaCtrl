// ── Media detection ───────────────────────────────────────────────────────────
// For known media sites, "playable" is decided from the URL itself rather
// than <video>/<audio> presence — a tag check is unreliable on these sites
// since homepage/profile pages also embed preview players that would get
// flagged as playable.
//
// urlLooksPlayable() returns true/false for a known "watch page" URL shape,
// or null for any other site, in which case checkAndReport() falls back to
// the <video>/<audio> tag check.
//
// MutationObserver catches dynamically injected players and re-fires
// checkAndReport on SPA navigations (e.g. YouTube home → /watch with no
// full page load).
//
// Double-injection guard: AHK reload re-injects this script into all tabs.
// If already running, just re-report state.

function urlLooksPlayable(hostname, pathname) {
    if (/(^|\.)youtube\.com$/.test(hostname)) {
        return pathname.startsWith("/watch") || pathname.includes("/shorts/");
    }
    if (/(^|\.)bilibili\.com$/.test(hostname)) {
        return pathname.includes("/video/");
    }
    if (/(^|\.)cycani\.org$/.test(hostname)) {
        return pathname.includes("/watch/");
    }
    // Not a site we special-case (includes douyin.com) — let the caller fall
    // back to the <video>/<audio> tag check.
    return null;
}

// Feed-style SPAs (Douyin) keep several <video> elements mounted at once —
// current, next, sometimes previous — for seamless scrolling. Grabbing the
// first <video> in DOM order (the old behavior) often hits a paused,
// off-screen element instead of the one actually playing.
//
// A bounding-box "most visible area" comparison turned out not to be robust
// either: feed slides are commonly laid out as full-viewport containers
// positioned via transforms, so several <video> elements can report the same
// area even when only one is actually on screen — the tie always resolves to
// whichever element comes first in DOM order, which explains getting stuck
// on one element permanently while scrolling forward.
//
// currentTime actually advancing is a much harder-to-fake signal than any
// single-snapshot paused/rect/visibility check, since a hidden or truly
// inactive video can't move its own playhead. We sample each video's
// currentTime on every call and compare to its previous sample.
function isActuallyAdvancing(v) {
    const now = performance.now();
    const last = v.__mediaCtrlLastSample;
    v.__mediaCtrlLastSample = { t: v.currentTime, at: now };
    if (!last) return !v.paused; // no baseline yet on first sight
    const dtWall = now - last.at;
    if (dtWall <= 0) return !v.paused;
    const dtVideo = v.currentTime - last.t;
    return !v.paused && dtVideo > 0.05;
}

function mostVisible(videos) {
    let best = null, bestArea = -1;
    for (const v of videos) {
        const style = getComputedStyle(v);
        if (style.visibility === "hidden" || style.display === "none" || parseFloat(style.opacity) === 0) continue;
        const r = v.getBoundingClientRect();
        const visibleW = Math.max(0, Math.min(r.right, window.innerWidth) - Math.max(r.left, 0));
        const visibleH = Math.max(0, Math.min(r.bottom, window.innerHeight) - Math.max(r.top, 0));
        const area = visibleW * visibleH;
        if (area > bestArea) { bestArea = area; best = v; }
    }
    return best;
}

function getActiveVideo() {
    const videos = Array.from(document.querySelectorAll("video"));
    if (videos.length === 0) return null;
    if (videos.length === 1) return videos[0];

    const advancing = videos.filter(v => !v.ended && v.readyState > 2 && isActuallyAdvancing(v));
    if (advancing.length === 1) return advancing[0];
    if (advancing.length > 1) return mostVisible(advancing) || advancing[0];

    // Nothing is genuinely advancing right now (e.g. mid swap/buffering) —
    // fall back to whichever is visibly on screen.
    return mostVisible(videos) || videos[0];
}

// Same "multiple elements, find the real one" problem as getActiveVideo(),
// applied to the a.cor5 next-episode/next-video link.
function getActiveCor5() {
    return Array.from(document.querySelectorAll("a.cor5"))
        .find(a => a.getAttribute("href") && !a.getAttribute("href").startsWith("javascript"))
        ?? null;
}

// Windows' SMTC status for the browser is Chrome's own guess about which
// <video> element backs the OS-level media session — and setting
// navigator.mediaSession.playbackState directly doesn't reliably override
// that guess. Douyin's own player almost certainly manages its own Media
// Session integration too (for its own OS lock-screen controls), and if its
// bookkeeping doesn't handle the multi-video swap cleanly, it can simply
// overwrite whatever we set moments later — a shared object we don't have
// exclusive control over. So beyond the (still harmless, complementary)
// mediaSession update, we also push our own ground-truth isPlaying straight
// through the extension's WebSocket bridge to AHK, bypassing Chrome/Windows'
// media-session relay entirely for this purpose.
function updatePlaybackState() {
    const video = getActiveVideo();
    const isPlaying = !!(video && !video.paused);

    if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = isPlaying ? "playing" : "paused";
    }

    if (isPlaying !== window.__mediaCtrlIsPlaying) {
        window.__mediaCtrlIsPlaying = isPlaying;
        chrome.runtime.sendMessage({ type: "playbackState", isPlaying });
    }
}

if (window.__mediaCtrlInjected) {
    // Already running — re-report current state to the freshly reconnected bridge
    chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: window.__mediaCtrlHasMedia });
    chrome.runtime.sendMessage({ type: "cor5Href",      href:     window.__mediaCtrlCor5Href });
    if (window.__mediaCtrlIsPlaying !== null)
        chrome.runtime.sendMessage({ type: "playbackState", isPlaying: window.__mediaCtrlIsPlaying });
} else {
    window.__mediaCtrlInjected  = true;
    window.__mediaCtrlHasMedia  = false;
    window.__mediaCtrlCor5Href  = null;
    window.__mediaCtrlLastUrl   = null;
    window.__mediaCtrlIsPlaying = null;

    function checkAndReport() {
        const urlResult = urlLooksPlayable(location.hostname, location.pathname);
        const found = urlResult !== null ? urlResult : !!(document.querySelector("video, audio"));
        // Re-report not just when hasMedia flips, but also when the URL itself
        // changes (e.g. Douyin's feed swaps to the next video via history.
        // pushState with no full reload). On feed sites hasMedia stays true
        // continuously across scrolling, so without this the background
        // script's tabMediaMap — and therefore Gate 2 in AHK's
        // _EvalVideoHotkeys — stays pinned to whichever video the tab
        // happened to be on when hasMedia first became true, causing the
        // current tab to look "not playable" on every video after the first.
        if (found !== window.__mediaCtrlHasMedia || location.href !== window.__mediaCtrlLastUrl) {
            window.__mediaCtrlHasMedia = found;
            window.__mediaCtrlLastUrl  = location.href;
            chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: found });
        }

        // There are multiple a.cor5 elements; find the one with a real href (not "javascript:")
        const cor5 = getActiveCor5();
        const href = cor5 ? cor5.getAttribute("href") : null;
        if (href !== window.__mediaCtrlCor5Href) {
            window.__mediaCtrlCor5Href = href;
            chrome.runtime.sendMessage({ type: "cor5Href", href });
        }

        updatePlaybackState();
    }

    checkAndReport();

    new MutationObserver(checkAndReport)
        .observe(document.documentElement, { childList: true, subtree: true });

    // MutationObserver only catches DOM structure changes — a plain play/pause
    // on an existing <video> doesn't mutate the DOM, so it needs its own
    // listeners. Media events don't bubble, but a capturing listener on
    // document still fires for them on the way down to the target, so this
    // catches play/pause/ended on any <video>, including ones added later.
    // Placed inside the first-injection guard so re-injection never registers
    // duplicate listeners.
    for (const evt of ["play", "pause", "playing", "ended", "emptied"]) {
        document.addEventListener(evt, updatePlaybackState, true);
    }

    // isActuallyAdvancing() needs a fresh currentTime sample regularly, not
    // just on DOM mutations or play/pause transitions, to have something to
    // compare against. A cheap once-a-second poll is enough for this purpose.
    setInterval(updatePlaybackState, 1000);
}

// ── AHK command handler ───────────────────────────────────────────────────────
// Registered unconditionally — safe to re-register, Chrome deduplicates listeners.

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    const cmd = msg.command;
    if (!cmd) return;

    if (cmd === "reportState") {
        // On-demand, synchronous re-check (independent of the cached
        // window.__mediaCtrlHasMedia flag) so background.js's recovery path
        // gets ground truth instead of trusting a push that may never arrive.
        const urlResult = urlLooksPlayable(location.hostname, location.pathname);
        const hasMedia  = urlResult !== null ? urlResult : !!(document.querySelector("video, audio"));
        sendResponse({ hasMedia, cor5Href: window.__mediaCtrlCor5Href ?? null });
        return;
    }

    if (cmd === "click_cor5") {
        const btn = getActiveCor5();
        if (btn) btn.click();

    } else if (cmd === "seek_0") {
        const video = getActiveVideo();
        if (video) video.currentTime = 0;

    } else if (cmd?.startsWith("speed_")) {
        const speed = parseFloat(cmd.replace("speed_", ""));
        if (!isNaN(speed)) {
            const video = getActiveVideo();
            if (video) {
                video.playbackRate = speed;
                // Some players (e.g. Netflix) reset playbackRate asynchronously.
                // Re-apply once after a short delay to win the race.
                setTimeout(() => { video.playbackRate = speed; }, 100);
            }
        }
    }
});
