// Reports this page's video state to background.js (→ AHK) and runs
// its commands: fullscreen via the F19 nudge, exit, seek, speed, hold-speed.
// Also evens out loudness between videos in the page (page leveler, AGC).
// Site and leveler settings come from chrome.storage.local "sites" /
// "leveler", written by background.js from AHK's Config.ahk.
(function () {
    if (window.__mediaCtrlInjected) return;
    window.__mediaCtrlInjected = true;

    const { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb, agcNew, agcUpdate, agcAverage, agcStartDb, agcVideoKey, agcIsNewVideo, agcSwitch, AGC_MEASURE_MS } = globalThis.pageLogic;

    const SEEK_GRACE_MS = 1500;   // ignore post-seek rebuffer "paused" blips
    const ARM_WINDOW_MS = 1000;   // armed nudge expires after this
    const BUTTON_WAIT_MS = 300;   // site button gets this long before the fallback
    const ENTER_SETTLE_MS = 500;  // a slow site button still gets this long before "enterFailed"
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
        if (site?.fsTarget) return document.querySelector(site.fsTarget);
        if (site?.playerSelector) return document.querySelector(site.playerSelector);
        return video?.parentElement ?? null;
    }

    // ── Page leveler (AGC) ──────────────────────────────────────────────────
    // Brings every video to the same loudness with one gain per video: its
    // first 3 s of sound are measured (K-weighted like a LUFS meter, so it
    // follows how loud it sounds rather than its raw energy), the gain moves
    // it toward leveler.targetDb — up for quiet videos, down for loud ones,
    // within maxBoostDb/maxCutDb — and is then locked for the rest of the
    // video, so it never drifts loud and quiet while you watch; only a
    // lasting much louder part turns it down (pageLogic.agcUpdate). A
    // limiter after it catches peaks. Silence holds the gain. Only on
    // leveler.sites (Douyin); elsewhere video plays untouched.
    // Each video is recognised (pageLogic.agcVideoKey) and its locked level
    // remembered for the page (agcSwitch), so:
    //   - the same video looping or replaying keeps its level;
    //   - a video scrolled back to starts straight at its known level, never
    //     above where an unknown one starts;
    //   - an unknown one starts at the gain a typical video locks at: the
    //     running average of how loud the site's videos are (agcAverage,
    //     agcStartDb), kept in chrome.storage.local "levelAvg" so it's known
    //     before the first video of a session plays. Each video counts once,
    //     when its gain locks; moving the site's volume
    //     slider forgets it (leveler.startDb until it's learnt again). Most
    //     videos then barely move; an unusual one is cut at once or comes up
    //     after 0.7 s of sound, and is locked after 3 s.
    // Feeds like Douyin reuse a few players as you scroll, so this is checked
    // whenever a player loads or starts a video, and for the active player on
    // every tick. Only that player's own gain changes, so a background player
    // (Douyin preloading the next item) never disturbs the one being watched.
    // Only for sources Web Audio can hear (pageLogic.audioProcessable) —
    // anything else would play silent — and only once the AudioContext is
    // running, or the routed video would be silent until a click. The state's
    // "leveled" flag says whether this page's video is levelled, and
    // "levelAvgDb" / "levelStartDb" what it has learnt (F6 shows them).

    const AGC_TICK_MS = 100;
    const AGC_DEFAULT_START_DB = -9;
    let levelAvg = null;           // the site's running average loudness in dB (storage "levelAvg")
    let audioCtx = null;
    let agcTimer = null;
    let activeVideo = null;        // from the last buildState() or "playing", so the
                                   // AGC loop doesn't disturb isActuallyAdvancing's sampling
    const agcs = new WeakMap();    // video -> { analyser, gain, buf, track, key, src, loads, seenLoads, counted }
    const agcMemory = new Map();   // video key -> its settled level (agcSwitch)
    let agcResuming = false;       // an AudioContext resume() is pending
    let agcSiteVolume = null;      // the site's own volume (slider) last seen

    // where an unheard video starts, and how far it may rise until it has
    // heard enough (pageLogic.agcUpdate), in dB
    function agcStart() {
        return agcStartDb(levelAvg, { ...leveler, startDb: leveler.startDb ?? AGC_DEFAULT_START_DB });
    }

    // a video heard long enough counts once towards the site's average
    function agcCount(agc) {
        if (agc.counted || agc.track.heardMs < AGC_MEASURE_MS) return;
        agc.counted = true;
        levelAvg = Math.round(agcAverage(levelAvg, agc.track.levelDb) * 100) / 100;
        chrome.storage.local.set({ levelAvg });
    }

    function levelVideo(video) {
        if (!leveler.enabled || !video || agcs.has(video)) return;
        if (!(leveler.sites ?? []).includes(currentSite()?.key)) return;
        if (!audioProcessable(video.currentSrc, location.origin, video.crossOrigin, !!video.srcObject)) return;
        try {
            if (!audioCtx) audioCtx = new AudioContext();
            if (audioCtx.state !== "running") {
                // a new AudioContext starts suspended even where it's allowed to
                // play, and runs a moment later: take the video over the moment
                // it does, not at the next report — until then it plays unlevelled.
                // Not allowed yet (no user gesture): the one pending resume
                // waits for it, and then takes over whichever video is active.
                if (!agcResuming) {
                    agcResuming = true;
                    audioCtx.resume().then(() => levelVideo(activeVideo ?? video))
                        .catch(() => {}).finally(() => { agcResuming = false; });
                }
                return;
            }
            const analyser = audioCtx.createAnalyser();
            analyser.fftSize = 4096;
            const gain = audioCtx.createGain();
            gain.gain.value = Math.pow(10, agcStart() / 20);
            const limiter = audioCtx.createDynamicsCompressor();
            limiter.threshold.value = leveler.limiterDb;
            limiter.knee.value = 0;
            limiter.ratio.value = 20;
            limiter.attack.value = 0.002;
            limiter.release.value = 0.1;
            // K-weighting (ITU-R BS.1770, as LUFS meters use), on the measuring
            // branch only: drop the deep bass ears barely hear as loudness and
            // lift the presence range they hear most — bass-heavy and voice-
            // heavy videos then measure the way they sound
            const highPass = audioCtx.createBiquadFilter();
            highPass.type = "highpass";
            highPass.frequency.value = 38;
            highPass.Q.value = 0.5;
            const presence = audioCtx.createBiquadFilter();
            presence.type = "highshelf";
            presence.frequency.value = 1500;
            presence.gain.value = 4;
            const source = audioCtx.createMediaElementSource(video);
            source.connect(highPass).connect(presence).connect(analyser);  // measured before the gain, so no feedback
            source.connect(gain).connect(limiter).connect(audioCtx.destination);
            const agc = { analyser, gain, buf: new Float32Array(analyser.fftSize), track: agcNew(),
                          key: null, src: null, loads: 0, seenLoads: 0, counted: false };
            agcs.set(video, agc);
            video.addEventListener("loadstart", () => agc.loads++);
            // the site's volume slider moved: the average and the levels
            // remembered for scrolled-back videos were heard at the old
            // volume — forget them, so new videos start at leveler.startDb
            // until the average is learnt again. Only the watched video
            // counts (the slider acts on it; Douyin also sets up background
            // players' volume), and mute / unmute isn't a change.
            video.addEventListener("volumechange", () => {
                if (video !== activeVideo) return;
                if (agcSiteVolume !== null && Math.abs(video.volume - agcSiteVolume) > 0.01) {
                    agcMemory.clear();
                    levelAvg = null;
                    chrome.storage.local.remove("levelAvg");
                }
                agcSiteVolume = video.volume;
            });
            // react the moment a player loads or starts a video, not on the next tick
            video.addEventListener("loadedmetadata", () => agcCheckVideo(video));
            // a video starting is the one being watched: measure it from its
            // first moment, not from the next report (up to a few hundred ms later)
            video.addEventListener("playing", () => {
                activeVideo = video;
                agcCheckVideo(video);
            });
            agcCheckVideo(video);
            if (!agcTimer) agcTimer = setInterval(agcTick, AGC_TICK_MS);
        } catch (e) {
            // e.g. the element is already routed by the page itself — leave it alone
        }
    }

    // set a video's gain now, as where it starts; until it has heard enough
    // to boost it won't rise above capDb (default: where it starts) — pageLogic.agcUpdate
    function agcSetGain(agc, value, capDb = 20 * Math.log10(value)) {
        agc.track.startDb = capDb;
        agc.gain.gain.cancelScheduledValues(audioCtx.currentTime);
        agc.gain.gain.setValueAtTime(value, audioCtx.currentTime);
    }

    // Has this player moved to another video (pageLogic.agcIsNewVideo)? Then
    // remember the old one's level and set the gain for the new one at once:
    // its known level, or the quiet start level if it's unknown. Same video
    // (loop, replay, a streamed player correcting its duration): the gain is
    // left alone — resetting it mid-video is an audible dip — and the key
    // stays the first one learnt in this load, which a reload of the video
    // (scrolling back) learns again.
    function agcCheckVideo(video) {
        const agc = agcs.get(video);
        if (!agc) return;
        const src = video.currentSrc;
        const key = agcVideoKey(src, video.duration);
        // the key just learnt is a video heard before: still worth jumping to
        // its known level while this one has barely been heard
        const learntKnown = agc.key === null && key !== null && agcMemory.has(key) && agc.track.heardMs < 1000;
        if (!agcIsNewVideo({ src: agc.src, loads: agc.seenLoads }, { src, loads: agc.loads }) && !learntKnown) {
            agc.key = agc.key ?? key;
            return;
        }
        const next = agcSwitch(agcMemory, agc.key, agc.track, key);
        agc.track = next.track;
        agc.key = key;
        agc.src = src;
        agc.seenLoads = agc.loads;
        agc.counted = next.known;  // a scrolled-back video was counted the first time
        // a known video starts at its level, but never louder than an unknown
        // one would: its duration key may belong to another clip, and its
        // boost comes back once it's re-checked (pageLogic.agcSwitch)
        const startDb = agcStart();
        if (next.known)
            agcSetGain(agc, Math.pow(10, Math.min(agcGainDb(next.track.levelDb, leveler), startDb) / 20));
        else
            agcSetGain(agc, Math.pow(10, startDb / 20), startDb);
    }

    function agcTick() {
        const video = activeVideo;
        const agc = video && agcs.get(video);
        if (!agc || video.paused || audioCtx.state !== "running") return;
        agcCheckVideo(video);
        agc.analyser.getFloatTimeDomainData(agc.buf);
        const db = rmsDb(agc.buf);
        if (!(db > leveler.silenceDb)) return;  // silence or a gap: hold the gain
        const gainDb = agcUpdate(agc.track, db, leveler, AGC_TICK_MS);
        agcCount(agc);
        // glide quickly while a new video is measured; a safety cut after it
        // is locked goes down gently
        const glideS = agc.track.heardMs <= AGC_MEASURE_MS ? 0.08 : 0.5;
        agc.gain.gain.setTargetAtTime(Math.pow(10, gainDb / 20), audioCtx.currentTime, glideS);
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
            // only configured sites: fullscreen elsewhere (the user's own)
            // mustn't bring up the clock or toggle Lossless Scaling
            isFullscreen: !!site && !!document.fullscreenElement,
            // also true while Chrome's own UI has focus (address bar, find
            // bar, dialogs): the page lacks focus, keys must pass through
            editableFocused: !document.hasFocus() || isEditable(innermostActive(document)),
            pageId,
            leveled: !!video && agcs.has(video),
            levelAvgDb: levelAvg === null ? null : Math.round(levelAvg),
            levelStartDb: Math.round(agcStart()),
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
        // a site with fsTarget is fullscreened directly, not through its button
        const button = site?.fsTarget ? null : findFsButton(site, video);
        if (button) {
            button.click();
            if (await waitForFullscreen(BUTTON_WAIT_MS)) return;
        }
        const target = fullscreenTarget(site, video);
        try {
            if (!target) throw new Error("no fullscreen target");
            await target.requestFullscreen();
        } catch (e) {
            // The site button's own request may just be slow (YouTube: up to
            // ~300 ms and more), and the fallback fails because that request
            // used the user activation. Give it ENTER_SETTLE_MS before asking
            // AHK for the fsKey fallback: a key like YouTube's "f" toggles, so
            // sent into a page that has just gone fullscreen it would exit.
            if (await waitForFullscreen(ENTER_SETTLE_MS)) return;
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

    // A <video> fed a live stream (srcObject — Douyin's newer player decodes
    // in the page) ignores currentTime and playbackRate; the site's own
    // player has to do it. Its player object isn't visible from this
    // isolated world, so douyinPlayer.js (page world) handles a
    // "mediactrl:control" event on the video — cmd: {to} / {by} seconds,
    // {rate}, or {get: "rate"} — and cancels it when the player did the job.
    function playerControl(video, cmd) {
        if (!video.srcObject) return false;
        const e = new CustomEvent("mediactrl:control", { detail: JSON.stringify(cmd), cancelable: true });
        return !video.dispatchEvent(e);
    }

    function getRate(video) {
        if (playerControl(video, { get: "rate" })) {
            const rate = parseFloat(video.getAttribute("data-mediactrl-rate"));
            if (rate > 0) return rate;
        }
        return video.playbackRate;
    }

    function setRate(video, rate) {
        const apply = () => { if (!playerControl(video, { rate })) video.playbackRate = rate; };
        apply();
        // some players reset playbackRate asynchronously
        setTimeout(apply, 100);
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
            if (playerControl(video, { to: msg.to, by: msg.by })) {
                // the site's player seeked
            } else if (typeof msg.to === "number") {
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
                holdSpeed = { video, rate: getRate(video), timer: setTimeout(endHoldSpeed, HOLD_SPEED_EXPIRE_MS) };
                setRate(video, msg.rate);
            } else if (!msg.on) {
                endHoldSpeed();
            }
        } else if (msg.type === "probe") {
            probe();
        }
    });

    // ── Triggers ────────────────────────────────────────────────────────────

    chrome.storage.local.get(["sites", "leveler", "levelAvg"], (s) => {
        sites = s.sites || {};
        leveler = s.leveler || {};
        levelAvg = s.levelAvg ?? null;
        report(true);
    });
    chrome.storage.onChanged.addListener((changes, area) => {
        if (area !== "local") return;
        if (changes.sites) sites = changes.sites.newValue || {};
        if (changes.leveler) leveler = changes.leveler.newValue || {};
        if (changes.levelAvg) levelAvg = changes.levelAvg.newValue ?? null;  // another tab learnt or forgot it
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
    // the page leveler takes over a video the instant it's loaded or starts,
    // not at the next state report (~250 ms later) — otherwise a brand-new
    // player's first moment plays unlevelled, at full volume
    for (const evt of ["loadedmetadata", "play"]) {
        document.addEventListener(evt, (e) => {
            if (e.target.tagName === "VIDEO" && currentSite()) levelVideo(e.target);
        }, true);
    }
    new MutationObserver(scheduleReport).observe(document.documentElement, { childList: true, subtree: true });
    // isActuallyAdvancing needs regular samples; also catches SPA URL changes
    setInterval(scheduleReport, 1000);
})();
