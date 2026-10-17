// Reports this page's video state to background.js (→ AHK) and runs
// its commands: fullscreen via the F19 nudge, exit, seek, speed, hold-speed.
// Also evens out loudness between videos in the page (page leveler, AGC).
// Site and leveler settings come from chrome.storage.local "sites" /
// "leveler", written by background.js from AHK's Config.ahk.
(function () {
    if (window.__mediaCtrlInjected) return;
    window.__mediaCtrlInjected = true;

    const { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb } = globalThis.pageLogic;

    const SEEK_GRACE_MS = 1500;   // ignore post-seek rebuffer "paused" blips
    const ARM_WINDOW_MS = 1000;   // armed nudge expires after this
    const BUTTON_WAIT_MS = 300;   // site button gets this long before the fallback
    const REPORT_THROTTLE_MS = 250;
    const HOLD_SPEED_EXPIRE_MS = 1500;  // AHK re-sends holdSpeed every 500 ms while held

    let sites = {};
    let leveler = {};
    let pageId = newPageId();
    let lastHref = location.href;
    let lastSent = "";
    let lastPlaying = false;
    let seekGraceUntil = 0;
    let armedUntil = 0;

    function newPageId() {
        return Math.random().toString(36).slice(2, 10);
    }

    function currentSite() {
        const key = matchSite(location.hostname, sites);
        return key ? { key, ...sites[key] } : null;
    }

    // ── Finding the real video ───────────────────────────────────────────────
    // Feed SPAs (Douyin) keep several <video>s mounted; currentTime actually
    // moving is harder to fake than a paused/visibility check.
    function isActuallyAdvancing(v) {
        const now = performance.now();
        const last = v.__mediaCtrlLastSample;
        v.__mediaCtrlLastSample = { t: v.currentTime, at: now };
        if (!last || now - last.at <= 0) return !v.paused;
        return !v.paused && v.currentTime - last.t > 0.05;
    }

    function mostVisible(videos) {
        let best = null, bestArea = -1;
        for (const v of videos) {
            const style = getComputedStyle(v);
            if (style.visibility === "hidden" || style.display === "none" || parseFloat(style.opacity) === 0) continue;
            const r = v.getBoundingClientRect();
            const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
            const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
            if (w * h > bestArea) { bestArea = w * h; best = v; }
        }
        return best;
    }

    // Sites with a playerSelector only count the video inside that player, so
    // hover-preview thumbnails elsewhere on the page are never "the video".
    function getActiveVideo(site) {
        if (site?.playerSelector) {
            return document.querySelector(site.playerSelector)?.querySelector("video") ?? null;
        }
        const videos = Array.from(document.querySelectorAll("video"));
        if (videos.length <= 1) return videos[0] ?? null;
        // hover previews sit inside a link to another page; the real player doesn't
        const nonThumb = videos.filter((v) => !v.closest('a[href], [role="link"]'));
        const candidates = nonThumb.length ? nonThumb : videos;
        const advancing = candidates.filter((v) => !v.ended && v.readyState > 2 && isActuallyAdvancing(v));
        if (advancing.length === 1) return advancing[0];
        if (advancing.length > 1) return mostVisible(advancing) || advancing[0];
        return mostVisible(candidates) || candidates[0];
    }

    // The fullscreen button belonging to the active video's own player —
    // feeds (Douyin) mount several players, so search outward from the video
    // instead of taking the first match on the page.
    function findFsButton(site, video) {
        if (!site?.fsButton) return null;
        for (let el = video?.parentElement; el; el = el.parentElement) {
            const button = el.querySelector(site.fsButton);
            if (button) return button;
        }
        return document.querySelector(site.fsButton);
    }

    // element requestFullscreen() targets when the site button isn't usable
    function fullscreenTarget(site, video) {
        if (site?.playerSelector) return document.querySelector(site.playerSelector);
        return video?.parentElement ?? null;
    }

    // ── Page leveler (AGC) ──────────────────────────────────────────────────
    // Brings every video to the same loudness: the video's sound is measured
    // (RMS over a few seconds) and a gain moves it toward leveler.targetDb —
    // up for quiet videos, down for loud ones, within maxBoostDb/maxCutDb — and
    // a limiter after it catches peaks. Silence holds the gain. A new video
    // starts from the last video's gain and settles fast.
    // Only for sources Web Audio can hear (pageLogic.audioProcessable) —
    // anything else would play silent — and only once the AudioContext is
    // running, or the routed video would be silent until a click. AHK's WASAPI
    // leveler stands down while the state says "leveled".

    const AGC_TICK_MS = 100;
    let audioCtx = null;
    let agcTimer = null;
    let agcLastGain = 1;
    let activeVideo = null;      // from the last buildState(), so the AGC loop
                                 // doesn't disturb isActuallyAdvancing's sampling
    const agcs = new WeakMap();  // video -> { analyser, gain, buf, levelDb, heardMs }

    function levelVideo(video) {
        if (!leveler.enabled || !video || agcs.has(video)) return;
        if (!audioProcessable(video.currentSrc, location.origin, video.crossOrigin)) return;
        try {
            if (!audioCtx) audioCtx = new AudioContext();
            if (audioCtx.state !== "running") {
                audioCtx.resume().catch(() => {});  // needs a user gesture; retried on the next report
                return;
            }
            const analyser = audioCtx.createAnalyser();
            analyser.fftSize = 4096;
            const gain = audioCtx.createGain();
            gain.gain.value = agcLastGain;
            const limiter = audioCtx.createDynamicsCompressor();
            limiter.threshold.value = leveler.limiterDb;
            limiter.knee.value = 0;
            limiter.ratio.value = 20;
            limiter.attack.value = 0.002;
            limiter.release.value = 0.1;
            const source = audioCtx.createMediaElementSource(video);
            source.connect(analyser);  // measured before the gain, so no feedback
            source.connect(gain).connect(limiter).connect(audioCtx.destination);
            agcs.set(video, { analyser, gain, buf: new Float32Array(analyser.fftSize), levelDb: null, heardMs: 0 });
            if (!agcTimer) agcTimer = setInterval(agcTick, AGC_TICK_MS);
        } catch (e) {
            // e.g. the element is already routed by the page itself — leave it alone
        }
    }

    function agcTick() {
        const video = activeVideo;
        const agc = video && agcs.get(video);
        if (!agc || video.paused || audioCtx.state !== "running") return;
        agc.analyser.getFloatTimeDomainData(agc.buf);
        const db = rmsDb(agc.buf);
        if (!(db > leveler.silenceDb)) return;  // silence or a gap: hold the gain
        agc.heardMs += AGC_TICK_MS;
        // averaging time grows to smoothingS over the first seconds of sound
        const tauMs = Math.min(leveler.smoothingS * 1000, agc.heardMs + 300);
        agc.levelDb = agc.levelDb === null ? db : agc.levelDb + (AGC_TICK_MS / tauMs) * (db - agc.levelDb);
        agcLastGain = Math.pow(10, agcGainDb(agc.levelDb, leveler) / 20);
        agc.gain.gain.setTargetAtTime(agcLastGain, audioCtx.currentTime, 0.3);
    }

    // ── State reporting ─────────────────────────────────────────────────────

    function buildState() {
        const site = currentSite();
        const video = site ? getActiveVideo(site) : null;

        let playing = !!(video && !video.paused);
        if (!playing && video && performance.now() < seekGraceUntil) playing = lastPlaying;
        lastPlaying = playing;

        const urlResult = site ? urlLooksPlayable(site.key, location.pathname) : false;
        const playable = urlResult !== null ? urlResult : !!video;
        const hasFsTarget = !!findFsButton(site, video) || !!fullscreenTarget(site, video);
        activeVideo = video;
        levelVideo(video);

        return {
            type: "state",
            url: location.href,
            site: site?.key ?? null,
            playable,
            playing,
            ready: playing && video.readyState >= 2 && hasFsTarget,
            isFullscreen: !!document.fullscreenElement,
            // also true while Chrome's own UI has focus (address bar, find
            // bar, dialogs): the page lacks focus, keys must pass through
            editableFocused: !document.hasFocus() || isEditable(innermostActive(document)),
            pageId,
            leveled: !!video && agcs.has(video),
        };
    }

    function report(force) {
        if (location.href !== lastHref) {
            lastHref = location.href;
            pageId = newPageId();
        }
        const state = buildState();
        const key = JSON.stringify(state);
        if (!force && key === lastSent) return;
        lastSent = key;
        chrome.runtime.sendMessage(state).catch(() => {});
    }

    let reportTimer = null;
    function scheduleReport() {
        if (reportTimer) return;
        reportTimer = setTimeout(() => { reportTimer = null; report(false); }, REPORT_THROTTLE_MS);
    }

    // ── Fullscreen via the F19 nudge ────────────────────────────────────────
    // Browsers only allow requestFullscreen() shortly after a real user
    // action. AHK's F19 is a real OS keypress, so while armed we use
    // it to click the site's own fullscreen button (its UI lays out right),
    // falling back to requestFullscreen() on the player.

    function waitForFullscreen(ms) {
        return new Promise((resolve) => {
            if (document.fullscreenElement) return resolve(true);
            const timer = setTimeout(() => { document.removeEventListener("fullscreenchange", onChange); resolve(false); }, ms);
            function onChange() {
                if (!document.fullscreenElement) return;
                clearTimeout(timer);
                document.removeEventListener("fullscreenchange", onChange);
                resolve(true);
            }
            document.addEventListener("fullscreenchange", onChange);
        });
    }

    async function enterFullscreenNow() {
        const site = currentSite();
        const video = getActiveVideo(site);
        const button = findFsButton(site, video);
        if (button) {
            button.click();
            if (await waitForFullscreen(BUTTON_WAIT_MS)) return;
        }
        const target = fullscreenTarget(site, video);
        try {
            if (!target) throw new Error("no fullscreen target");
            await target.requestFullscreen();
        } catch (e) {
            chrome.runtime.sendMessage({ type: "enterFailed", pageId }).catch(() => {});
        }
    }

    document.addEventListener("keydown", (e) => {
        if (e.key !== "F19") return;
        if (!e.isTrusted || performance.now() > armedUntil) return;
        armedUntil = 0;
        e.preventDefault();
        e.stopImmediatePropagation();
        enterFullscreenNow();
    }, true);

    // ── Click on the video surface ──────────────────────────────────────────
    // Reported on "click" (after mouseup), not mousedown: leaving fullscreen
    // mid-press made YouTube read a held button (2x speed) and kept Bilibili/
    // Douyin from seeing a full click, so they never paused.
    // elementsFromPoint so a transparent click-catcher over the <video> still
    // counts; controls are excluded by being interactive or too small.
    const INTERACTIVE = 'button, a, input, select, textarea, summary, [role="button"], [role="link"], [role="menuitem"], [role="tab"], [role="checkbox"], [role="switch"], [role="slider"], [contenteditable="true"]';
    document.addEventListener("click", (e) => {
        if (!e.isTrusted || !document.fullscreenElement) return;  // real clicks only
        const stack = document.elementsFromPoint(e.clientX, e.clientY);
        const video = stack.find((el) => el.tagName === "VIDEO");
        const top = stack[0];
        if (!video || !top || top.closest(INTERACTIVE)) return;
        if (top !== video && !coversVideo(top.getBoundingClientRect(), video.getBoundingClientRect())) return;
        chrome.runtime.sendMessage({ type: "videoClick" }).catch(() => {});
    }, true);

    // ── Debug probe: which selectors match, and fullscreen-button candidates ─

    function probe() {
        const site = currentSite();
        const hits = {
            fsButton: !!findFsButton(site, getActiveVideo(site)),
            playerSelector: !!(site?.playerSelector && document.querySelector(site.playerSelector)),
            videos: document.querySelectorAll("video").length,
        };
        const candidates = [];
        for (const el of document.querySelectorAll("[class], [aria-label], [title], [data-e2e]")) {
            const text = [el.className?.baseVal ?? el.className, el.getAttribute("aria-label"), el.getAttribute("title"), el.getAttribute("data-e2e")].join(" ");
            if (/full.?screen|全屏/i.test(text)) {
                candidates.push({ tag: el.tagName, cls: String(el.className?.baseVal ?? el.className).slice(0, 80), aria: el.getAttribute("aria-label"), e2e: el.getAttribute("data-e2e") });
                if (candidates.length >= 15) break;
            }
        }
        const video = getActiveVideo(site) || document.querySelector("video");
        const parents = [];
        for (let el = video?.parentElement; el && parents.length < 6; el = el.parentElement) {
            parents.push({ tag: el.tagName, id: el.id, cls: String(el.className).slice(0, 80) });
        }
        chrome.runtime.sendMessage({ type: "probeResult", site: site?.key ?? null, hits, candidates, videoParents: parents }).catch(() => {});
    }

    // ── Commands from AHK ───────────────────────────────────────────────────

    let holdSpeed = null;  // { video, rate, timer } while d / Right is held

    // restores the speed from before the hold — on release, or when AHK's
    // keep-alive stops arriving (bridge dropped mid-hold)
    function endHoldSpeed() {
        if (!holdSpeed) return;
        clearTimeout(holdSpeed.timer);
        setRate(holdSpeed.video, holdSpeed.rate);
        holdSpeed = null;
    }

    function setRate(video, rate) {
        video.playbackRate = rate;
        // some players reset playbackRate asynchronously
        setTimeout(() => { video.playbackRate = rate; }, 100);
    }

    chrome.runtime.onMessage.addListener((msg) => {
        const video = getActiveVideo(currentSite());
        if (msg.type === "reportNow") {
            report(true);
        } else if (msg.type === "armFullscreen") {
            armedUntil = performance.now() + ARM_WINDOW_MS;
            chrome.runtime.sendMessage({ type: "armed", pageId }).catch(() => {});
        } else if (msg.type === "exitFullscreen") {
            if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
        } else if (msg.type === "seek" && video) {
            if (typeof msg.to === "number") {
                video.currentTime = msg.to;
            } else if (typeof msg.by === "number") {
                const max = isFinite(video.duration) ? video.duration : Infinity;
                video.currentTime = Math.max(0, Math.min(video.currentTime + msg.by, max));
            }
            seekGraceUntil = performance.now() + SEEK_GRACE_MS;
            setTimeout(() => report(false), SEEK_GRACE_MS + 50);
        } else if (msg.type === "speed" && video && typeof msg.rate === "number") {
            // an explicit speed wins over a hold in progress
            if (holdSpeed) { clearTimeout(holdSpeed.timer); holdSpeed = null; }
            setRate(video, msg.rate);
        } else if (msg.type === "holdSpeed") {
            // d / Right held in AHK: fast while held, then back to the rate
            // (and the video) it was before, even if the feed moved on
            if (msg.on && holdSpeed) {
                clearTimeout(holdSpeed.timer);  // keep-alive
                holdSpeed.timer = setTimeout(endHoldSpeed, HOLD_SPEED_EXPIRE_MS);
            } else if (msg.on && video && typeof msg.rate === "number") {
                holdSpeed = { video, rate: video.playbackRate, timer: setTimeout(endHoldSpeed, HOLD_SPEED_EXPIRE_MS) };
                setRate(video, msg.rate);
            } else if (!msg.on) {
                endHoldSpeed();
            }
        } else if (msg.type === "probe") {
            probe();
        }
    });

    // ── Triggers ────────────────────────────────────────────────────────────

    chrome.storage.local.get(["sites", "leveler"], (s) => {
        sites = s.sites || {};
        leveler = s.leveler || {};
        report(true);
    });
    chrome.storage.onChanged.addListener((changes, area) => {
        if (area !== "local") return;
        if (changes.sites) sites = changes.sites.newValue || {};
        if (changes.leveler) leveler = changes.leveler.newValue || {};
        if (changes.sites || changes.leveler) report(true);
    });

    document.addEventListener("fullscreenchange", () => report(false));
    // focus changes report at once, so the first letters typed into a box
    // aren't swallowed by the video keys
    document.addEventListener("focusin", () => report(false), true);
    document.addEventListener("focusout", () => setTimeout(() => report(false), 0), true);
    window.addEventListener("focus", () => report(false));
    window.addEventListener("blur", () => report(false));
    for (const evt of ["play", "pause", "playing", "ended", "emptied", "loadeddata"]) {
        document.addEventListener(evt, scheduleReport, true);
    }
    new MutationObserver(scheduleReport).observe(document.documentElement, { childList: true, subtree: true });
    // isActuallyAdvancing needs regular samples; also catches SPA URL changes
    setInterval(scheduleReport, 1000);
})();
