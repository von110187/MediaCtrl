// Pure page helpers — no DOM or chrome.* access, so node tests can load them.
// Loaded before content.js (see manifest.json), exposed as globalThis.pageLogic.
(function () {
    // siteKey whose `match` domain is the hostname or a parent of it, else null
    function matchSite(hostname, sites) {
        for (const key in sites) {
            const domain = sites[key].match;
            if (hostname === domain || hostname.endsWith("." + domain)) return key;
        }
        return null;
    }

    // true/false for sites with known watch-page URLs; null means "decide by
    // whether there's an active video" (Douyin's feed has no watch-page URL)
    function urlLooksPlayable(siteKey, pathname) {
        if (siteKey === "youtube") return pathname.startsWith("/watch") || pathname.includes("/shorts/");
        if (siteKey === "bilibili") return pathname.includes("/video/");
        return null;
    }

    // A genuine click on the video surface lands on an element covering most
    // of the video; player control chrome (gear, volume, progress bar) is a
    // small icon or bar near an edge.
    function coversVideo(topRect, videoRect, ratio = 0.8) {
        const videoArea = (videoRect.right - videoRect.left) * (videoRect.bottom - videoRect.top);
        if (videoArea <= 0) return false;
        const overlapW = Math.max(0, Math.min(topRect.right, videoRect.right) - Math.max(topRect.left, videoRect.left));
        const overlapH = Math.max(0, Math.min(topRect.bottom, videoRect.bottom) - Math.max(topRect.top, videoRect.top));
        return overlapW * overlapH >= videoArea * ratio;
    }

    const TEXT_INPUT_TYPES = ["text", "search", "email", "url", "tel", "password", "number"];

    // true when keystrokes would type into this element. A focused IFRAME
    // counts: the content script only runs in the top frame, so it can't see
    // which field inside the frame has focus (e.g. YouTube live chat).
    function isEditable(el) {
        if (!el) return false;
        if (el.isContentEditable) return true;
        if (el.tagName === "IFRAME") return true;
        if (el.tagName === "TEXTAREA" || el.tagName === "SELECT") return true;
        if (el.tagName === "INPUT") return TEXT_INPUT_TYPES.includes((el.type || "text").toLowerCase());
        return false;
    }

    // document.activeElement stops at a shadow host (Bilibili's comment box
    // lives inside <bili-comments>'s shadow root) — follow it to the real field
    function innermostActive(root) {
        let el = root.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        return el ?? null;
    }

    // Whether a <video>'s audio can go through Web Audio without being muted:
    // cross-origin media without CORS plays silent once routed there, and an
    // element can never be un-routed. MSE players (YouTube, Bilibili) use
    // blob: URLs, which are fine.
    function audioProcessable(src, pageOrigin, crossOriginAttr) {
        if (!src) return false;
        if (src.startsWith("blob:")) return true;
        if (crossOriginAttr) return true;  // the element would fail to load at all without CORS
        try {
            return new URL(src).origin === pageOrigin;
        } catch (e) {
            return false;
        }
    }

    // RMS level of a block of samples, in dBFS (-Infinity for silence)
    function rmsDb(samples) {
        let sum = 0;
        for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
        return 10 * Math.log10(sum / samples.length);
    }

    // Page leveler (AGC): gain in dB that brings a measured level to
    // cfg.targetDb, at most cfg.maxBoostDb up and cfg.maxCutDb down
    function agcGainDb(levelDb, cfg) {
        return Math.max(-cfg.maxCutDb, Math.min(cfg.maxBoostDb, cfg.targetDb - levelDb));
    }

    const api = { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb };
    globalThis.pageLogic = api;
    if (typeof module !== "undefined") module.exports = api;
})();
