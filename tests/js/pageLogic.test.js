const test = require("node:test");
const assert = require("node:assert");
const { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb, agcNew, agcUpdate, agcStart, agcVideoKey, agcIsNewVideo, agcSwitch } = require("../../Extension/lib/pageLogic.js");

const sites = {
    youtube: { match: "youtube.com" },
    bilibili: { match: "bilibili.com" },
    douyin: { match: "douyin.com" },
};

test("matchSite matches the domain and its subdomains only", () => {
    assert.strictEqual(matchSite("www.youtube.com", sites), "youtube");
    assert.strictEqual(matchSite("m.bilibili.com", sites), "bilibili");
    assert.strictEqual(matchSite("youtube.com", sites), "youtube");
    assert.strictEqual(matchSite("notyoutube.com", sites), null);
});

test("urlLooksPlayable knows watch pages per site", () => {
    assert.strictEqual(urlLooksPlayable("youtube", "/watch"), true);
    assert.strictEqual(urlLooksPlayable("youtube", "/shorts/abc"), true);
    assert.strictEqual(urlLooksPlayable("youtube", "/"), false);
    assert.strictEqual(urlLooksPlayable("bilibili", "/video/BV1xx"), true);
    assert.strictEqual(urlLooksPlayable("bilibili", "/"), false);
    assert.strictEqual(urlLooksPlayable("douyin", "/"), null);
});

test("coversVideo needs the clicked element to cover most of the video", () => {
    const video = { left: 0, top: 0, right: 100, bottom: 100 };
    assert.strictEqual(coversVideo({ left: 0, top: 0, right: 100, bottom: 100 }, video), true);
    assert.strictEqual(coversVideo({ left: 0, top: 0, right: 40, bottom: 40 }, video), false);
    assert.strictEqual(coversVideo({ left: 0, top: 0, right: 100, bottom: 100 }, { left: 0, top: 0, right: 0, bottom: 0 }), false);
});

test("isEditable is true only for text entry", () => {
    assert.strictEqual(isEditable({ tagName: "INPUT", type: "search" }), true);
    assert.strictEqual(isEditable({ tagName: "INPUT", type: "text" }), true);
    assert.strictEqual(isEditable({ tagName: "INPUT", type: "range" }), false);
    assert.strictEqual(isEditable({ tagName: "TEXTAREA" }), true);
    assert.strictEqual(isEditable({ tagName: "DIV", isContentEditable: true }), true);
    assert.strictEqual(isEditable({ tagName: "DIV" }), false);
    assert.strictEqual(isEditable(null), false);
});

test("isEditable treats a focused iframe as typing (e.g. YouTube live chat)", () => {
    assert.strictEqual(isEditable({ tagName: "IFRAME" }), true);
});

test("innermostActive looks inside shadow roots", () => {
    const textarea = { tagName: "TEXTAREA" };
    const doc = { activeElement: { tagName: "BILI-COMMENTS", shadowRoot: { activeElement: { tagName: "DIV", shadowRoot: { activeElement: textarea } } } } };
    assert.strictEqual(innermostActive(doc), textarea);
    assert.strictEqual(innermostActive({ activeElement: { tagName: "BODY" } }).tagName, "BODY");
    assert.strictEqual(innermostActive({ activeElement: null }), null);
});

// Routing a <video> through Web Audio outputs silence when its media is
// cross-origin without CORS, and that can't be undone — so only safe sources.
test("audioProcessable allows only sources Web Audio can hear", () => {
    const page = "https://www.youtube.com";
    assert.strictEqual(audioProcessable("blob:https://www.youtube.com/0a1b", page, null), true, "MSE blob");
    assert.strictEqual(audioProcessable("https://www.youtube.com/v.mp4", page, null), true, "same origin");
    assert.strictEqual(audioProcessable("https://cdn.example.com/v.mp4", page, null), false, "cross-origin, no CORS");
    assert.strictEqual(audioProcessable("https://cdn.example.com/v.mp4", page, "anonymous"), true, "CORS-enabled element");
    assert.strictEqual(audioProcessable("", page, null), false, "nothing loaded yet");
    assert.strictEqual(audioProcessable("not a url", page, null), false);
});

test("rmsDb measures loudness in dBFS", () => {
    assert.strictEqual(Math.round(rmsDb(new Float32Array(100).fill(1))), 0, "full scale");
    assert.strictEqual(Math.round(rmsDb(new Float32Array(100).fill(0.1))), -20);
    assert.strictEqual(rmsDb(new Float32Array(100)), -Infinity, "silence");
});

// AGC: quiet videos come up, loud ones come down, toward one target level
test("agcGainDb moves toward the target within the limits", () => {
    const cfg = { targetDb: -20, maxBoostDb: 18, maxCutDb: 18 };
    assert.strictEqual(agcGainDb(-20, cfg), 0, "already on target");
    assert.strictEqual(agcGainDb(-30, cfg), 10, "quiet video boosted");
    assert.strictEqual(agcGainDb(-10, cfg), -10, "loud video cut");
    assert.strictEqual(agcGainDb(-60, cfg), 18, "boost capped");
    assert.strictEqual(agcGainDb(5, cfg), -18, "cut capped");
});

// AGC level tracking: a fresh measurement settles fast; a long-running one is steady
const cfg = { targetDb: -20, maxBoostDb: 18, maxCutDb: 18, smoothingS: 3 };
const TICK = 100;
function feed(agc, db, ticks) { for (let i = 0; i < ticks; i++) agcUpdate(agc, db, cfg, TICK); }

test("agcUpdate: a new video settles within about half a second", () => {
    const agc = agcNew();
    feed(agc, -10, 100);                 // a loud video for 10 s
    const fresh = agcNew();              // the next video starts fresh
    feed(fresh, -40, 5);                 // 0.5 s of a quiet video
    assert.ok(Math.abs(fresh.levelDb - -40) < 1, "fresh: " + fresh.levelDb);
});

test("agcUpdate: without a reset, a long-running measurement is slow to move", () => {
    const agc = agcNew();
    feed(agc, -10, 100);
    feed(agc, -40, 5);                   // the same quiet 0.5 s, no reset
    assert.ok(agc.levelDb > -25, "steady: " + agc.levelDb);
});

test("agcUpdate returns the gain for the current level, once settled", () => {
    const agc = agcNew();
    feed(agc, -30, 20);                  // 2 s: past the no-boost start
    assert.strictEqual(agcUpdate(agc, -30, cfg, TICK), 10);
});

// a new video starts a little under where the louder of the last few videos
// settled (their lower quartile gain, minus a 3 dB margin), so it follows the
// site's own volume slider: loud (slider high) → a big cut, quiet (slider
// low) → about none. While settling it may rise to that recent level, never
// above it and never above 0 dB. With nothing heard yet: the fixed first level.
test("agcStart: nothing heard yet uses the first level", () => {
    assert.deepStrictEqual(agcStart([], -9), { startDb: -9, capDb: -9 });
});

test("agcStart follows the recent videos, a margin under the louder ones", () => {
    assert.deepStrictEqual(agcStart([-16, -18, -17], -9), { startDb: -21, capDb: -18 }, "few videos: the loudest");
    assert.deepStrictEqual(agcStart([-15.2, -12.3, -10.4, 4.9, -13.4], -9), { startDb: -16.4, capDb: -13.4 }, "a mixed feed (Douyin trace)");
    assert.deepStrictEqual(agcStart([-16, -18, -40, -17, -15], -9), { startDb: -21, capDb: -18 }, "one very loud video doesn't decide it");
});

test("agcStart: a quiet site slider means a start near full level, not the fixed first level", () => {
    // Douyin at 35 %: recent videos settled with little or no cut
    assert.deepStrictEqual(agcStart([-1, 2, 0, -2, 1], -9), { startDb: -4, capDb: -1 });
});

test("agcStart never starts or settles boosted", () => {
    assert.deepStrictEqual(agcStart([6, 10, 4], -9), { startDb: -3, capDb: 0 });
});

// many clips open with near-silence or a fade-in: that must not open the
// gain above where the video started, or the real sound right after plays
// up to 14 dB too loud (Douyin trace: -50, -20 dB, then -12, -10 dB)
test("agcUpdate: a fade-in doesn't raise a new video above its start gain", () => {
    const agc = agcNew();
    agc.startDb = -12;
    for (const db of [-50, -20.4, -12.6, -9.6, -11.1]) {
        const g = agcUpdate(agc, db, cfg, TICK);
        assert.ok(g <= -12, `block ${db}: gain ${g.toFixed(1)}`);
    }
});

test("agcUpdate: a quiet video still comes up once settled", () => {
    const agc = agcNew();
    agc.startDb = -12;
    feed(agc, -36, 14);                  // the first 1.4 s: held at the start gain
    assert.strictEqual(agcUpdate(agc, -36, cfg, TICK), 16, "then its full boost");
});

// while a new video settles its level is the power average of everything
// heard so far, so one quiet gap or one loud blip early on doesn't swing the
// gain (blocks from a Douyin trace: the old fast follower moved the gain by
// up to 4 dB a tick here)
test("agcUpdate: a new video's level is steady through gaps and blips", () => {
    const agc = agcNew();
    const gains = [-11.8, -5.3, -9.2, -17.3, -41, -7.4, -5.8, -11.3].map((db) => agcUpdate(agc, db, cfg, TICK));
    for (let i = 2; i < gains.length; i++) {
        assert.ok(Math.abs(gains[i] - gains[i - 1]) < 1.5, `tick ${i}: ${gains[i - 1].toFixed(1)} -> ${gains[i].toFixed(1)}`);
    }
});

// telling videos apart: a plain URL is the video; streamed (blob:) players get
// a new URL every load, so their exact duration identifies the video instead
test("agcVideoKey: URL for plain sources, duration for streamed ones", () => {
    assert.strictEqual(agcVideoKey("https://v.douyin.com/a.mp4", 14.37), "https://v.douyin.com/a.mp4");
    assert.strictEqual(agcVideoKey("blob:https://www.douyin.com/1f2e", 14.371), "dur:14.37");
    assert.strictEqual(agcVideoKey("blob:https://www.douyin.com/1f2e", NaN), null, "duration not known yet");
    assert.strictEqual(agcVideoKey("", 10), "dur:10.00");
});

// only a new source or load is a new video; a loop, a replay or a duration
// corrected while buffering (Douyin, ~0.6 s in) is the same one
test("agcIsNewVideo: only a new source or load is a new video", () => {
    const prev = { src: "blob:a", loads: 1 };
    assert.strictEqual(agcIsNewVideo(prev, { src: "blob:b", loads: 1 }), true, "new src");
    assert.strictEqual(agcIsNewVideo(prev, { src: "blob:a", loads: 2 }), true, "reloaded");
    assert.strictEqual(agcIsNewVideo(prev, { src: "blob:a", loads: 1 }), false, "same load");
});

test("agcSwitch: an unknown video starts fresh", () => {
    const cache = new Map();
    const r = agcSwitch(cache, null, null, "dur:10.00");
    assert.strictEqual(r.known, false);
    assert.strictEqual(r.track.levelDb, null);
});

test("agcSwitch: scrolling back restores the video's settled level", () => {
    const cache = new Map();
    const settled = { levelDb: -12, heardMs: 4000 };
    agcSwitch(cache, "dur:10.00", settled, "dur:20.00");            // leave video A
    const back = agcSwitch(cache, "dur:20.00", agcNew(), "dur:10.00"); // back to A
    assert.strictEqual(back.known, true);
    assert.strictEqual(back.track.levelDb, -12);
    back.track.levelDb = -30;                                         // it keeps measuring...
    assert.strictEqual(cache.get("dur:10.00").levelDb, -12, "...without changing the stored copy");
});

// a duration key can match a different clip of the same length: a restored
// level must re-check itself fast and without boosting, like a new video,
// for its first moment — a loud clip mistaken for a quiet remembered one
// mustn't play boosted for seconds
test("agcSwitch: a restored level re-checks itself fast at first", () => {
    const cache = new Map();
    agcSwitch(cache, "dur:15.30", { levelDb: -32, heardMs: 9000 }, "dur:20.00");  // a quiet clip, +12 dB
    const back = agcSwitch(cache, "dur:20.00", agcNew(), "dur:15.30");
    assert.ok(back.track.heardMs >= 1000, "still counts as heard: " + back.track.heardMs);
    assert.ok(agcUpdate(back.track, -32, cfg, TICK) <= 0, "no boost in its first moment");
    feed(back.track, -8, 3);                                                       // it's actually loud
    assert.ok(back.track.levelDb > -14, "a loud clip is followed fast: " + back.track.levelDb);
    feed(back.track, -32, 50);
    assert.ok(agcUpdate(back.track, -32, cfg, TICK) > 0, "boost allowed again once checked");
});

test("agcSwitch: a barely-heard video isn't remembered", () => {
    const cache = new Map();
    agcSwitch(cache, "dur:10.00", { levelDb: -12, heardMs: 300 }, "dur:20.00");
    assert.strictEqual(cache.has("dur:10.00"), false);
});

test("agcSwitch: remembers at most 200 videos, dropping the oldest", () => {
    const cache = new Map();
    for (let i = 0; i < 205; i++) agcSwitch(cache, "v" + i, { levelDb: -20, heardMs: 2000 }, "next");
    assert.strictEqual(cache.size, 200);
    assert.ok(!cache.has("v0") && cache.has("v204"));
});

// A new video's loud start is followed within a fraction of a second; once
// settled, a short loud moment (a hit, a shout) barely moves the level — the
// limiter handles it — while a lasting louder stretch is followed in seconds.
// A quiet one only slowly, so a quiet stretch can't leave a big boost in place.
test("agcUpdate: follows a new video's loud start fast", () => {
    const fresh = agcNew();
    feed(fresh, -30, 3);                 // 0.3 s of a quiet intro
    feed(fresh, -10, 3);                 // then 0.3 s of loud
    assert.ok(fresh.levelDb > -14, "loud followed fast: " + fresh.levelDb);
});

test("agcUpdate: once settled, a short loud moment doesn't duck the video", () => {
    const agc = agcNew();
    feed(agc, -30, 50);                  // settled on a quiet video
    feed(agc, -10, 3);                   // 0.3 s of loud
    assert.ok(agc.levelDb < -25, "barely moved: " + agc.levelDb);
    feed(agc, -10, 47);                  // the loud part lasts 5 s
    assert.ok(agc.levelDb > -12, "a lasting change is followed: " + agc.levelDb);
});

test("agcUpdate: follows a quieter sound slowly", () => {
    const down = agcNew();
    feed(down, -10, 50);                 // settled on a loud video
    feed(down, -30, 3);                  // 0.3 s of quiet
    assert.ok(down.levelDb > -14, "quiet followed slowly: " + down.levelDb);
});

// While a new video settles it may only be turned down, never up: a quiet
// first moment must not leave a boost in place for the loud part after it
test("agcUpdate: no boost in a new video's first 1.5 s", () => {
    const agc = agcNew();
    feed(agc, -40, 10);                  // 1 s of a quiet intro
    assert.strictEqual(agcUpdate(agc, -40, cfg, TICK), 0, "no boost yet");
    feed(agc, -40, 10);                  // past 1.5 s
    assert.ok(agcUpdate(agc, -40, cfg, TICK) > 0, "boost allowed after settling");
    const loud = agcNew();
    assert.ok(agcUpdate(loud, -5, cfg, TICK) < 0, "cuts are allowed at once");
});
