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

    // Page leveler level tracking for one video. A fresh tracker settles fast
    // (its averaging time starts at 0.4 s and grows to cfg.smoothingS over
    // the first seconds of sound); a long-running one is steady, so quiet
    // moments within a video aren't pumped up. Start a fresh one for every
    // new video.
    function agcNew() {
        return { levelDb: null, heardMs: 0 };
    }

    const AGC_ATTACK_MS = 200;     // a louder sound is followed within ~0.2 s
    const AGC_NO_BOOST_MS = 1500;  // a new video may only be turned down this long

    // one measured block (dB, already known not to be silence) → the gain in
    // dB to apply now. Fast down, slow up, as broadcast levelers do: louder
    // sound is followed at once, quieter sound over the averaging time — so a
    // quiet stretch can't leave a big boost in place when it gets loud. And no
    // boost at all while a new video settles: a quiet first moment must not
    // boost the loud part right after it.
    function agcUpdate(agc, db, cfg, dtMs) {
        agc.heardMs += dtMs;
        if (agc.levelDb === null) {
            agc.levelDb = db;
        } else {
            const tauMs = db > agc.levelDb ? AGC_ATTACK_MS : Math.min(cfg.smoothingS * 1000, agc.heardMs + 300);
            agc.levelDb += Math.min(1, dtMs / tauMs) * (db - agc.levelDb);
        }
        const gainDb = agcGainDb(agc.levelDb, cfg);
        return agc.heardMs < AGC_NO_BOOST_MS ? Math.min(gainDb, 0) : gainDb;
    }

    // gain (linear) a new video starts at, before its first measurement: at
    // most startDb (e.g. -6 dB = half), lower if the previous video needed a
    // bigger cut. Starting a bit quiet is harmless; starting loud isn't.
    function agcStartGain(lastGain, startDb) {
        return Math.min(lastGain, Math.pow(10, startDb / 20));
    }

    // Which video is this, for the page leveler's memory? A plain URL is the
    // video itself; streamed players (blob: URLs) get a new URL on every load,
    // so their exact duration identifies the video instead. null until the
    // duration is known.
    function agcVideoKey(src, duration) {
        if (src && !src.startsWith("blob:")) return src;
        return isFinite(duration) && duration > 0 ? "dur:" + duration.toFixed(2) : null;
    }

    const AGC_MEMORY = 200;   // videos remembered per page
    const AGC_SETTLED_MS = 1000;

    // The player moved from video oldKey (its tracker oldTrack) to newKey.
    // Remembers the old video's level if it had settled, and returns the
    // tracker to use: a copy of the remembered one (known: true) or a fresh
    // one (known: false).
    function agcSwitch(cache, oldKey, oldTrack, newKey) {
        if (oldKey !== null && oldTrack && oldTrack.heardMs >= AGC_SETTLED_MS) {
            cache.delete(oldKey);  // re-insert as the newest
            cache.set(oldKey, { levelDb: oldTrack.levelDb, heardMs: oldTrack.heardMs });
            if (cache.size > AGC_MEMORY) cache.delete(cache.keys().next().value);
        }
        const saved = newKey !== null ? cache.get(newKey) : undefined;
        return saved ? { track: { ...saved }, known: true } : { track: agcNew(), known: false };
    }

    const api = { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb, agcNew, agcUpdate, agcStartGain, agcVideoKey, agcSwitch };
    globalThis.pageLogic = api;
    if (typeof module !== "undefined") module.exports = api;
})();
