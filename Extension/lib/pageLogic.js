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
    // blob: URLs, which are fine; so is a stream attached as srcObject
    // (Douyin, on Chrome versions with MSE in a worker), which has no URL.
    function audioProcessable(src, pageOrigin, crossOriginAttr, hasSrcObject = false) {
        if (hasSrcObject) return true;
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

    // Page leveler level tracking for one video: measured over its first
    // AGC_MEASURE_MS of sound, then held (agcUpdate). Start a fresh one for
    // every new video.
    function agcNew() {
        return { levelDb: null, heardMs: 0, sumPow: 0, blocks: 0, loudMs: 0, loudPow: 0, loudBlocks: 0 };
    }

    const AGC_MEASURE_MS = 3000;   // a new video's level is measured over this much sound, then its gain is locked
    const AGC_NO_BOOST_MS = 700;   // ...and it may only be turned down until it has heard this much
    const AGC_SAFETY_DB = 6;       // locked: sound this much louder than measured...
    const AGC_SAFETY_MS = 2000;    // ...for this long turns the video down to it

    // one measured block (dB, already known not to be silence) → the gain in
    // dB to apply now. One gain per video, so it never drifts loud and quiet
    // while it plays:
    //   - measuring (the first AGC_MEASURE_MS of sound; silence isn't
    //     measured): the level is the power average of every block so far,
    //     as a LUFS meter integrates — a gap or a blip barely moves it, and
    //     loud blocks weigh most, so it errs towards turning down. Until
    //     AGC_NO_BOOST_MS of it the gain never rises above where it started
    //     (agc.startDb, set by the caller: agcStartDb; never above 0 dB):
    //     many clips open with a fade-in, and opening the gain for it would
    //     play the real sound right after it too loud. A remembered level
    //     being re-checked (agc.checking, agcSwitch) isn't boosted at all;
    //   - then the level is locked. Only a safety cut moves it: sound more
    //     than AGC_SAFETY_DB louder for AGC_SAFETY_MS (quiet talk, then loud
    //     music — the limiter only catches peaks) raises it to that loud
    //     part's level, so the video is turned down, never back up. Quieter
    //     blocks wind the timer back down rather than restarting it, so
    //     music's beats don't hide a loud part.
    function agcUpdate(agc, db, cfg, dtMs) {
        agc.heardMs += dtMs;
        const pow = Math.pow(10, db / 10);
        const measuring = agc.heardMs <= AGC_MEASURE_MS || agc.levelDb === null;
        if (measuring) {
            agc.sumPow += pow;
            agc.blocks++;
            agc.levelDb = 10 * Math.log10(agc.sumPow / agc.blocks);
        } else if (db > agc.levelDb + AGC_SAFETY_DB) {
            agc.loudMs += dtMs;
            agc.loudPow += pow;
            agc.loudBlocks++;
            if (agc.loudMs >= AGC_SAFETY_MS) {
                agc.levelDb = 10 * Math.log10(agc.loudPow / agc.loudBlocks);
                agc.loudMs = agc.loudPow = agc.loudBlocks = 0;
            }
        } else if (agc.loudMs > 0) {
            agc.loudMs = Math.max(0, agc.loudMs - dtMs);
            if (!agc.loudMs) agc.loudPow = agc.loudBlocks = 0;
        }
        const gainDb = agcGainDb(agc.levelDb, cfg);
        const noBoost = measuring && (agc.checking || agc.blocks * dtMs < AGC_NO_BOOST_MS);
        return noBoost ? Math.min(gainDb, 0, agc.startDb ?? 0) : gainDb;
    }

    const AGC_AVERAGE_OF = 20;   // the Douyin average follows about this many videos

    // The page leveler's running average of how loud the site's videos are
    // (dB, measured as agcUpdate does), one locked video at a time. null:
    // nothing heard yet.
    function agcAverage(avgDb, levelDb) {
        if (avgDb === null || avgDb === undefined) return levelDb;
        return avgDb + (levelDb - avgDb) / AGC_AVERAGE_OF;
    }

    // Where every new video starts, in dB: the gain a typical video (the
    // average) settles at, so most start where they end up. Never a boost —
    // a quiet one comes up once heard (agcUpdate). No average yet:
    // cfg.startDb.
    function agcStartDb(avgDb, cfg) {
        if (avgDb === null || avgDb === undefined) return cfg.startDb;
        return Math.round(Math.min(0, agcGainDb(avgDb, cfg)) * 10) / 10;
    }

    // Which video is this, for the page leveler's memory? A plain URL is the
    // video itself; streamed players (blob: URLs) get a new URL on every load,
    // so their exact duration identifies the video instead. null until the
    // duration is known.
    function agcVideoKey(src, duration) {
        if (src && !src.startsWith("blob:")) return src;
        return isFinite(duration) && duration > 0 ? "dur:" + duration.toFixed(2) : null;
    }

    // Has a player moved to another video? prev / now: { src, loads } (loads
    // counts the player's loadstart events). A new source or a new load is a
    // new video; anything else — a loop, a replay, a streamed player
    // correcting its duration as it buffers (Douyin does, ~0.6 s in) — is
    // the same one.
    function agcIsNewVideo(prev, now) {
        return prev.src !== now.src || prev.loads !== now.loads;
    }

    const AGC_MEMORY = 200;   // videos remembered per page
    const AGC_SETTLED_MS = 1000;
    const AGC_RECHECK_MS = 500;

    // The player moved from video oldKey (its tracker oldTrack) to newKey.
    // Remembers the old video's level if it had settled, and returns the
    // tracker to use: the remembered one (known: true) or a fresh one
    // (known: false). A remembered one keeps its level and how much it was
    // measured over, and is checked again for AGC_RECHECK_MS without a
    // boost: a duration key can match a different clip of the same length,
    // and a louder one moves the level, weighted against the blocks already
    // measured, so a matching video keeps its gain.
    function agcSwitch(cache, oldKey, oldTrack, newKey) {
        if (oldKey !== null && oldTrack && oldTrack.heardMs >= AGC_SETTLED_MS) {
            cache.delete(oldKey);  // re-insert as the newest
            cache.set(oldKey, { levelDb: oldTrack.levelDb, heardMs: oldTrack.heardMs, blocks: oldTrack.blocks });
            if (cache.size > AGC_MEMORY) cache.delete(cache.keys().next().value);
        }
        const saved = newKey !== null ? cache.get(newKey) : undefined;
        if (!saved) return { track: agcNew(), known: false };
        const blocks = Math.max(1, saved.blocks || 0);
        return { track: { ...agcNew(), levelDb: saved.levelDb, blocks, sumPow: Math.pow(10, saved.levelDb / 10) * blocks,
                          heardMs: Math.min(saved.heardMs, AGC_MEASURE_MS - AGC_RECHECK_MS), checking: true }, known: true };
    }

    const api = { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb, agcNew, agcUpdate, agcAverage, agcStartDb, agcVideoKey, agcIsNewVideo, agcSwitch, AGC_MEASURE_MS };
    globalThis.pageLogic = api;
    if (typeof module !== "undefined") module.exports = api;
})();
