// ── WebSocket to AHK bridge ───────────────────────────────────────────────────
const WS_URL = "ws://127.0.0.1:9224";

let ws          = null;
let reconnTimer = null;
let lastPongAt  = 0;

// tabId → url, for tabs that have a media element (in ANY of their frames —
// see all_frames note below)
const tabMediaMap = new Map();

// The most recently activated (i.e. clicked/focused) tab, tracked directly
// via chrome.tabs.onActivated/onUpdated rather than queried on demand via
// {active:true, currentWindow:true} at command time. Queried on demand is
// what speed_* used to broadcast to every tab with media to work around
// (see sendCommandToVideoFrame below) — Chrome's "active tab" can be
// ambiguous while the browser window is in fullscreen (no on-screen tab
// strip to click, focus can sit oddly), so a live-tracked value here is a
// more reliable target than trusting a query result at the moment a command
// arrives.
let lastActiveTabId = null;

// tabId → frameId, for the specific frame within a tab that most recently
// reported owning a <video> element (content.js's "frameHasVideo" message).
// Needed because content.js now runs in every frame (all_frames: true in
// manifest.json), not just the top one — some sites (cycani.org) put their
// real <video> inside a cross-origin player iframe, so a command like
// seek_0/speed_* has to be targeted at that specific frame, not the tab's
// top frame, or it'll silently find no <video> and do nothing.
const tabVideoFrameMap = new Map();

function connect() {
    if (reconnTimer) { clearTimeout(reconnTimer); reconnTimer = null; }

    lastPongAt = Date.now(); // reset so a fresh connection gets a full grace window
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
        console.log("[MediaCtrl] Connected to AHK bridge");
        // Don't call pushPlayableTabs() here — tabMediaMap is freshly empty
        // after a service-worker restart. reinjectAllTabs() below confirms
        // each tab's state with retries and pushes once done, so the list
        // rebuilds correctly without going through a false-empty state.
        //
        // lastActiveTabId is also freshly null after a service-worker
        // restart (onActivated won't fire again for a tab the user already
        // switched to before this worker instance existed) — seed it here
        // so a speed_* command arriving before the user's next tab switch
        // still has a real target instead of falling through to a live query.
        chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
            if (tab) lastActiveTabId = tab.id;
        });
        reinjectAllTabs();
        pushCurrentTab();
    };

    ws.onmessage = async (event) => {
        try {
            const data = JSON.parse(event.data);
            if (data.pong !== undefined) {
                lastPongAt = Date.now();
                return;
            }
            if (data.navigate) {
                const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
                if (tab) chrome.tabs.update(tab.id, { url: data.navigate });
            } else if (data.command) {
                // Previously, speed_* was broadcast to every tab in
                // tabMediaMap to work around {active:true} being unreliable
                // while the browser is in fullscreen — but that meant
                // pressing 1/2/3/4 changed playback speed on every open
                // tab with media, not just the one being watched (e.g.
                // YouTube in the background would speed up right along with
                // the cycani.org tab actually in fullscreen). Route to a
                // single target tab instead: lastActiveTabId, tracked live
                // via onActivated/onUpdated below, which doesn't depend on
                // querying "active" at the moment the command arrives and so
                // isn't subject to whatever fullscreen-focus ambiguity the
                // broadcast was originally guarding against.
                const targetTabId = tabMediaMap.has(lastActiveTabId)
                    ? lastActiveTabId
                    : (await chrome.tabs.query({ active: true, currentWindow: true }))[0]?.id;
                if (targetTabId !== undefined) await sendCommandToVideoFrame(targetTabId, data.command);
            }
        } catch (e) {}
    };

    ws.onclose = () => { reconnTimer = setTimeout(connect, 2000); };
    ws.onerror = () => { ws.close(); };
}

// Sends a video-targeted command (seek_0, speed_*) to the frame within tabId
// that last reported owning a <video> (tabVideoFrameMap). If no frame has
// reported one yet (e.g. a very fresh page where frameHasVideo hasn't fired),
// falls back to sendMessage with no frameId, which fans the command out to
// every frame in the tab — harmless, since content.js's handlers for these
// commands call getActiveVideo(), which simply no-ops in any frame that
// doesn't have a <video>.
async function sendCommandToVideoFrame(tabId, command) {
    const frameId = tabVideoFrameMap.get(tabId);
    try {
        if (frameId !== undefined) {
            await chrome.tabs.sendMessage(tabId, { command }, { frameId });
        } else {
            await chrome.tabs.sendMessage(tabId, { command });
        }
    } catch (e) {}
}

// ── Content script messages ───────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!sender.tab) return;
    const { id: tabId, url } = sender.tab;
    const frameId = sender.frameId;

    if (msg.type === "mediaPresence") {
        if (!url?.startsWith("http")) return;
        console.log(`[MediaCtrl] tab ${tabId} (${url}): mediaPresence push -> hasMedia=${msg.hasMedia}`);
        if (msg.hasMedia) {
            tabMediaMap.set(tabId, url);
        } else {
            tabMediaMap.delete(tabId);
        }
        pushPlayableTabs();
    } else if (msg.type === "cor5Href") {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify({ cor5Href: msg.href }));
    } else if (msg.type === "playbackState") {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify({ extPlaying: msg.isPlaying }));
    } else if (msg.type === "videoClick") {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify({ videoClick: true }));
    } else if (msg.type === "frameHasVideo") {
        // Record/clear which frame in this tab currently owns a <video>, so
        // seek_0/speed_* commands can be routed straight to it. Only ever
        // clear the mapping if the frame that's clearing it is the one
        // currently recorded — otherwise an unrelated frame's "false" report
        // (e.g. a stale iframe navigating away) could wipe out a different,
        // still-valid frame's entry.
        if (msg.hasVideo) {
            tabVideoFrameMap.set(tabId, frameId);
        } else if (tabVideoFrameMap.get(tabId) === frameId) {
            tabVideoFrameMap.delete(tabId);
        }
    }
});

// ── Tab lifecycle ─────────────────────────────────────────────────────────────

chrome.tabs.onRemoved.addListener((tabId) => {
    if (tabMediaMap.has(tabId)) {
        tabMediaMap.delete(tabId);
        pushPlayableTabs();
    }
    tabVideoFrameMap.delete(tabId);
    if (lastActiveTabId === tabId) lastActiveTabId = null;
});

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
    // Don't eagerly remove from tabMediaMap on URL change — the content script
    // will report mediaPresence:false on the new page if there's no media.
    // Removing here causes a gap where the tab briefly disappears from playableTabs
    // during SPA navigations (e.g. YouTube) before the new page reports in.
    if (change.url || change.status === "complete")
        pushCurrentTab();
    // A real navigation invalidates any previously recorded video frame for
    // this tab — the new page (and its frames) will re-report via
    // frameHasVideo once loaded, so stale routing doesn't linger.
    if (change.url)
        tabVideoFrameMap.delete(tabId);
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
    lastActiveTabId = tabId;
    pushCurrentTab();
});

// ── Push helpers ──────────────────────────────────────────────────────────────

function pushCurrentTab() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
        const url = tab?.url ?? "";
        if (url.startsWith("http"))
            ws.send(JSON.stringify({ url }));
    });
}

function pushPlayableTabs() {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
        console.warn(`[MediaCtrl] pushPlayableTabs: socket not open (readyState=${ws?.readyState}) — not sent. tabMediaMap currently has ${tabMediaMap.size} entries.`);
        return;
    }
    const entries = Array.from(tabMediaMap.entries()).map(([tabId, url]) => tabId + "|" + url);
    console.log(`[MediaCtrl] pushPlayableTabs: sending ${entries.length} tab(s)`, entries);
    ws.send(JSON.stringify({ playingTabs: entries }));
}

// ── Startup injection ─────────────────────────────────────────────────────────
// Re-inject content.js into all existing http tabs when the bridge connects.
// This recovers playable tab state after an AHK reload without needing manual refreshes.

async function reinjectAllTabs() {
    const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
    console.log(`[MediaCtrl] reinjectAllTabs: found ${tabs.length} http(s) tabs`, tabs.map(t => t.id + ":" + t.url));
    // Settle all tabs concurrently, then push once with the complete result.
    // content.js's own spontaneous mediaPresence message still arrives and
    // pushes too — this is just a verified backstop in case that fire-and-
    // forget message gets lost.
    await Promise.allSettled(tabs.map((tab) => reportTabState(tab.id, tab.url)));
    console.log(`[MediaCtrl] reinjectAllTabs: done, tabMediaMap now has ${tabMediaMap.size} entr${tabMediaMap.size === 1 ? "y" : "ies"}`, Array.from(tabMediaMap.entries()));
    pushPlayableTabs();
}

async function reportTabState(tabId, url, attempt = 1) {
    try {
        // allFrames: true — matches manifest.json's all_frames:true for the
        // static injection. Some sites (cycani.org) put their real <video>
        // inside a cross-origin player iframe, invisible to a top-frame-only
        // injection; re-injecting into every frame here keeps this recovery
        // path (used after an AHK/bridge reload) consistent with normal
        // page-load injection, instead of silently losing video-frame
        // detection specifically on reconnect.
        await chrome.scripting.executeScript({
            target: { tabId, allFrames: true },
            files: ["content.js"],
        });
    } catch (e) {
        // Tab may not be injectable (e.g. chrome:// pages, PDFs) — skip silently
        console.log(`[MediaCtrl] tab ${tabId} (${url}): executeScript failed — ${e.message}`);
        return;
    }

    try {
        // frameId: 0 is always the top frame. hasMedia/cor5Href are top-frame-
        // only concerns (see content.js's "Frame awareness" notes) — without
        // pinning this to frameId 0, sendMessage would fan out to every frame
        // in the tab (including the video iframe on sites like cycani.org)
        // and, per Chrome's own docs, resolve to whichever frame answers
        // first, which could just as easily be a subframe's hasMedia:false.
        // A subframe with the real <video> reports itself separately and
        // asynchronously via its own "frameHasVideo" push once its copy of
        // content.js runs, so it doesn't need to be polled here.
        const response = await chrome.tabs.sendMessage(tabId, { command: "reportState" }, { frameId: 0 });
        console.log(`[MediaCtrl] tab ${tabId} (${url}): reportState ->`, response);
        if (response?.hasMedia) tabMediaMap.set(tabId, url);
        else tabMediaMap.delete(tabId);
    } catch (e) {
        // The script injected fine but didn't answer in time — happens on
        // backgrounded/throttled or just-discarded tabs racing the reconnect.
        // Retry a few times with a short delay rather than silently dropping
        // this tab out of playableTabs until the user manually reloads it.
        console.log(`[MediaCtrl] tab ${tabId} (${url}): sendMessage failed on attempt ${attempt} — ${e.message}`);
        if (attempt < 3) {
            await new Promise((resolve) => setTimeout(resolve, 300));
            return reportTabState(tabId, url, attempt + 1);
        }
        console.warn(`[MediaCtrl] tab ${tabId} (${url}): gave up after ${attempt} attempts`);
        // Gave up — leave tabMediaMap's existing entry (if any) untouched
        // rather than guessing either way.
    }
}

// ── Service worker keepalive / watchdog ───────────────────────────────────────
// Chrome kills this service worker after ~30s of inactivity, and an idle
// WebSocket doesn't count as activity — so the worker (and its reconnect
// timer) can die mid-session with no chance to recover on its own.
//
// chrome.alarms survives worker termination and wakes it on schedule,
// regardless of what else happened. 30s is the minimum period Chrome allows.
const HEARTBEAT_ALARM = "mediactrl-heartbeat";
chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });

chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== HEARTBEAT_ALARM) return;

    if (!ws || ws.readyState === WebSocket.CLOSED) {
        // Connection is down (or this is a fresh worker instance) — reconnect.
        // connect()'s ws.onopen will reinject content scripts into every tab,
        // which repairs any tab whose media state was lost when the previous
        // worker instance (and its tabMediaMap) was terminated.
        connect();
    } else if (ws.readyState === WebSocket.OPEN) {
        // readyState alone isn't trustworthy — a bridge-side hang or a
        // half-torn-down loopback socket can leave it stuck at OPEN with
        // no close/error event ever firing. Require a pong within 2 missed
        // intervals (90s) before trusting it, otherwise force a reconnect.
        if (Date.now() - lastPongAt > 90000) {
            console.warn("[MediaCtrl] No pong in 90s — connection looks dead, forcing reconnect");
            try { ws.close(); } catch (e) {}
        } else {
            try { ws.send(JSON.stringify({ ping: Date.now() })); } catch (e) {}
        }
    }
});

connect();