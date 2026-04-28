// ── Media detection ───────────────────────────────────────────────────────────
// Reports whether this page has a <video> or <audio> element.
// MutationObserver catches dynamically injected players (SPAs, YouTube, etc.)
//
// Double-injection guard: AHK reload causes background.js to re-inject this
// script into all existing tabs. If already running, just re-report state.

if (window.__mediaCtrlInjected) {
    // Already running — re-report current state to the freshly reconnected bridge
    chrome.runtime.sendMessage({ type: "mediaPresence", hasMedia: window.__mediaCtrlHasMedia });
    chrome.runtime.sendMessage({ type: "cor5Href",      href:     window.__mediaCtrlCor5Href });
} else {
    window.__mediaCtrlInjected  = true;
    window.__mediaCtrlHasMedia  = false;
    window.__mediaCtrlCor5Href  = null;

    function checkAndReport() {
        const found = !!(document.querySelector("video, audio"));
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

chrome.runtime.onMessage.addListener((msg) => {
    const cmd = msg.command;
    if (!cmd) return;

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
