// Frame awareness: manifest.json injects into every frame (all_frames: true).
// Some sites (cycani.org) embed <video> inside a cross-origin iframe that's
// invisible to the top frame, so this script must also run inside it directly.
// URL-based playability (urlLooksPlayable, a.cor5) only makes sense against
// the top-level page, so those stay gated to isTopFrame. <video>-based
// detection runs in every frame — getActiveVideo() just no-ops where there's
// nothing to find.
const isTopFrame = window === window.top;

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
    return null;
}

// Feed-style SPAs (Douyin) keep several <video> elements mounted at once, so
// "first in DOM order" or a single visibility snapshot often picks the wrong
// one. currentTime actually advancing is a harder-to-fake signal than a
// paused/rect check, since a hidden or inactive video can't move its own
// playhead.
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

// YouTube's hover-preview thumbnails autoplay muted <video> elements
// independent of the real player, which could otherwise win the
// advancing/visibility heuristics below and falsely report "playing" from a
// hover alone. #movie_player is YouTube's stable player container, so if it
// has a <video>, that's authoritative and skips the heuristics entirely.
function getYouTubeRealPlayerVideo() {
    if (!/(^|\.)youtube\.com$/.test(location.hostname)) return null;
    const player = document.getElementById("movie_player");
    if (!player) return null;
    return player.querySelector("video");
}

function getActiveVideo() {
    const ytVideo = getYouTubeRealPlayerVideo();
    if (ytVideo) return ytVideo;

    const videos = Array.from(document.querySelectorAll("video"));
    if (videos.length === 0) return null;
    if (videos.length === 1) return videos[0];

    const advancing = videos.filter(v => !v.ended && v.readyState > 2 && isActuallyAdvancing(v));
    if (advancing.length === 1) return advancing[0];
    if (advancing.length > 1) return mostVisible(advancing) || advancing[0];

    return mostVisible(videos) || videos[0];
}

// Top-frame-only — see frame awareness note above.
function getActiveCor5() {
    return Array.from(document.querySelectorAll("a.cor5"))
        .find(a => a.getAttribute("href") && !a.getAttribute("href").startsWith("javascript"))
        ?? null;
}

// Windows' SMTC status is the browser's own guess about which <video> backs
// the OS media session, and can get stuck stale (e.g. Douyin swapping videos
// mid-scroll). We push our own ground-truth isPlaying through the WebSocket
// bridge to AHK instead of relying on that relay.
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

    // Lets background.js route seek_0/speed_* to whichever frame actually
    // has the video, not just the top frame.
    const hasVideo = !!video;
    if (hasVideo !== window.__mediaCtrlHasVideo) {
        window.__mediaCtrlHasVideo = hasVideo;
        chrome.runtime.sendMessage({ type: "frameHasVideo", hasVideo });
    }
}

if (window.__mediaCtrlInjected) {
    // Already running (AHK reload re-injects into all tabs) — just re-report
    // current state to the freshly reconnected bridge.
    if (isTopFrame) {
        chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: window.__mediaCtrlHasMedia });
        chrome.runtime.sendMessage({ type: "cor5Href",      href:     window.__mediaCtrlCor5Href });
    }
    if (window.__mediaCtrlIsPlaying !== null)
        chrome.runtime.sendMessage({ type: "playbackState", isPlaying: window.__mediaCtrlIsPlaying });
    if (window.__mediaCtrlHasVideo)
        chrome.runtime.sendMessage({ type: "frameHasVideo", hasVideo: true });
} else {
    window.__mediaCtrlInjected  = true;
    window.__mediaCtrlHasMedia  = false;
    window.__mediaCtrlCor5Href  = null;
    window.__mediaCtrlLastUrl   = null;
    window.__mediaCtrlIsPlaying = null;
    window.__mediaCtrlHasVideo  = false;

    function checkAndReport() {
        if (isTopFrame) {
            const urlResult = urlLooksPlayable(location.hostname, location.pathname);
            const found = urlResult !== null ? urlResult : !!(document.querySelector("video, audio"));
            // Also re-report on URL change alone (e.g. Douyin's feed swaps
            // via pushState with no reload) — otherwise hasMedia stays true
            // continuously across scrolling and Gate 2 in AHK stays pinned
            // to whichever video was first seen.
            if (found !== window.__mediaCtrlHasMedia || location.href !== window.__mediaCtrlLastUrl) {
                window.__mediaCtrlHasMedia = found;
                window.__mediaCtrlLastUrl  = location.href;
                chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: found });
            }

            const cor5 = getActiveCor5();
            const href = cor5 ? cor5.getAttribute("href") : null;
            if (href !== window.__mediaCtrlCor5Href) {
                window.__mediaCtrlCor5Href = href;
                chrome.runtime.sendMessage({ type: "cor5Href", href });
            }
        }

        updatePlaybackState();
    }

    checkAndReport();

    new MutationObserver(checkAndReport)
        .observe(document.documentElement, { childList: true, subtree: true });

    // MutationObserver doesn't catch plain play/pause with no DOM mutation.
    // Capture phase since some players stopPropagation() on their own clicks.
    for (const evt of ["play", "pause", "playing", "ended", "emptied"]) {
        document.addEventListener(evt, updatePlaybackState, true);
    }

    // Reports whether a mousedown landed on the <video> surface, so AHK's
    // LButton hotkey can tell a genuine click-to-pause apart from clicks on
    // comments, controls, etc. elementsFromPoint (not e.target) so an overlay
    // control layer above the <video> is still detected correctly.
    //
    // "VIDEO somewhere in the stack" alone is too permissive: control chrome
    // (settings gear, volume, progress bar) commonly overlays the video's
    // bounding box, so it still shows up in the stack. Most such controls
    // also aren't marked up semantically (no <button>/role) — YouTube's
    // ytp-button class is one example among many bespoke <div>/<span> icon
    // controls sitewide — so a tag/role check alone doesn't generalize.
    //
    // The structural signal that does generalize: control chrome is a small
    // icon/bar near an edge, while a genuine video-surface click target (the
    // <video> itself, or a transparent click-catcher some players layer over
    // it) covers essentially the whole video area. So compare the topmost
    // element's bounding box against the video's, in addition to the
    // semantic check (which still catches large interactive overlays, e.g.
    // a big play/pause button, that would otherwise pass the size check).
    function isVideoSurfaceClick(topmost, video) {
        if (topmost === video) return true;
        const vr = video.getBoundingClientRect();
        const videoArea = vr.width * vr.height;
        if (videoArea <= 0) return false;
        const tr = topmost.getBoundingClientRect();
        const overlapW = Math.max(0, Math.min(tr.right, vr.right) - Math.max(tr.left, vr.left));
        const overlapH = Math.max(0, Math.min(tr.bottom, vr.bottom) - Math.max(tr.top, vr.top));
        const overlapArea = overlapW * overlapH;
        return overlapArea >= videoArea * 0.8; // must cover the large majority of the video
    }

    const INTERACTIVE_SELECTOR = 'button, a, input, select, textarea, summary, [role="button"], [role="link"], [role="menuitem"], [role="tab"], [role="checkbox"], [role="switch"], [role="slider"], [contenteditable="true"]';
    document.addEventListener("mousedown", (e) => {
        const stack = document.elementsFromPoint(e.clientX, e.clientY);
        const video = stack.find((el) => el.tagName === "VIDEO");
        if (!video) return;

        const topmost = stack[0];
        if (topmost && topmost.closest(INTERACTIVE_SELECTOR)) return;
        if (!isVideoSurfaceClick(topmost, video)) return;

        chrome.runtime.sendMessage({ type: "videoClick" });
    }, true);

    // isActuallyAdvancing() needs a fresh currentTime sample regularly to
    // have something to compare against, not just on mutations/play/pause.
    setInterval(updatePlaybackState, 1000);
}

// Registered unconditionally — Chrome deduplicates listeners on re-injection.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    const cmd = msg.command;
    if (!cmd) return;

    if (cmd === "reportState") {
        // On-demand synchronous re-check for background.js's recovery path,
        // independent of the cached hasMedia flag.
        const urlResult = isTopFrame ? urlLooksPlayable(location.hostname, location.pathname) : null;
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
                setTimeout(() => { video.playbackRate = speed; }, 100);
            }
        }
    }
});
