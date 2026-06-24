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
        return pathname.includes("/video");
    }
    if (/(^|\.)cycani\.org$/.test(hostname)) {
        return pathname.includes("/watch/");
    }
    // Not a site we special-case (includes douyin.com) — let the caller fall
    // back to the <video>/<audio> tag check.
    return null;
}

if (window.__mediaCtrlInjected) {
    // Already running — re-report current state to the freshly reconnected bridge
    chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: window.__mediaCtrlHasMedia });
    chrome.runtime.sendMessage({ type: "cor5Href",      href:     window.__mediaCtrlCor5Href });
} else {
    window.__mediaCtrlInjected  = true;
    window.__mediaCtrlHasMedia  = false;
    window.__mediaCtrlCor5Href  = null;

    function checkAndReport() {
        const urlResult = urlLooksPlayable(location.hostname, location.pathname);
        const found = urlResult !== null ? urlResult : !!(document.querySelector("video, audio"));
        if (found !== window.__mediaCtrlHasMedia) {
            window.__mediaCtrlHasMedia = found;
            chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: found });
        }

        // There are multiple a.cor5 elements; find the one with a real href (not "javascript:")
        const cor5 = Array.from(document.querySelectorAll("a.cor5"))
            .find(a => a.getAttribute("href") && !a.getAttribute("href").startsWith("javascript"));
        const href = cor5 ? cor5.getAttribute("href") : null;
        if (href !== window.__mediaCtrlCor5Href) {
            window.__mediaCtrlCor5Href = href;
            chrome.runtime.sendMessage({ type: "cor5Href", href });
        }
    }

    checkAndReport();

    new MutationObserver(checkAndReport)
        .observe(document.documentElement, { childList: true, subtree: true });
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
        const btn = document.querySelector("a.cor5");
        if (btn) btn.click();

    } else if (cmd?.startsWith("speed_")) {
        const speed = parseFloat(cmd.replace("speed_", ""));
        if (!isNaN(speed)) {
            const video = document.querySelector("video");
            if (video) {
                video.playbackRate = speed;
                // Some players (e.g. Netflix) reset playbackRate asynchronously.
                // Re-apply once after a short delay to win the race.
                setTimeout(() => { video.playbackRate = speed; }, 100);
            }
        }
    }
});
