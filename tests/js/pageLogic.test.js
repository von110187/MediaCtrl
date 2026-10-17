const test = require("node:test");
const assert = require("node:assert");
const { matchSite, urlLooksPlayable, coversVideo, isEditable, innermostActive, audioProcessable, rmsDb, agcGainDb } = require("../../Extension/lib/pageLogic.js");

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
