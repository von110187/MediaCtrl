// ── WebSocket to AHK bridge ───────────────────────────────────────────────────
const WS_URL = "ws://127.0.0.1:9224";

let ws          = null;
let reconnTimer = null;
let lastPongAt  = 0;

// tabId → url, for tabs with media in any frame (see all_frames note below)
const tabMediaMap = new Map();

// Live-tracked "active tab" via onActivated/onUpdated, not queried on demand —
// Chrome's active-tab query is ambiguous while the window is fullscreen (no
// tab strip, focus can sit oddly), so a query at command-time isn't reliable.
let lastActiveTabId = null;

// tabId → frameId that most recently reported owning a <video>
// (content.js's "frameHasVideo"). Needed because content.js runs in every
// frame (all_frames: true) — some sites (cycani.org) put the real <video>
// in a cross-origin iframe, so seek_0/speed_* must target that frame
// specifically or it'll silently find nothing.
const tabVideoFrameMap = new Map();

function connect() {
    if (reconnTimer) { clearTimeout(reconnTimer); reconnTimer = null; }

    lastPongAt = Date.now(); // reset so a fresh connection gets a full grace window
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
        console.log("[MediaCtrl] Connected to AHK bridge");
        // Don't push tabMediaMap here — it's freshly empty after a worker
        // restart. reinjectAllTabs() confirms each tab with retries and
        // pushes once done.
        //
        // lastActiveTabId is also freshly null after a restart (onActivated
        // won't refire for a tab switched to earlier) — seed it here so a
        // speed_* command has a real target before the next tab switch.
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
                // Route to lastActiveTabId rather than broadcasting to every
                // tab with media — a prior broadcast approach meant 1/2/3/4
                // changed playback speed on every open tab, not just the one
                // being watched.
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

// Sends seek_0/speed_* to the frame that last reported owning a <video>.
// Falls back to fanning out to every frame if none has reported yet —
// harmless, since content.js's handlers no-op in frames with no <video>.
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
        // Only clear the mapping if the clearing frame is the one currently
        // recorded, so a stale/navigating-away frame can't wipe out a
        // different still-valid frame's entry.
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
    // Don't eagerly remove from tabMediaMap on URL change — content.js will
    // report mediaPresence:false itself if there's no media on the new page.
    // Removing here would blank the tab out of playableTabs during SPA
    // navigations before the new page reports in.
    if (change.url || change.status === "complete")
        pushCurrentTab();
    // real navigation invalidates any previously recorded video frame
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
// Re-inject content.js into all http tabs on bridge connect, recovering
// playable-tab state after an AHK reload without manual refreshes.

async function reinjectAllTabs() {
    const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
    console.log(`[MediaCtrl] reinjectAllTabs: found ${tabs.length} http(s) tabs`, tabs.map(t => t.id + ":" + t.url));
    // settle concurrently, then push once with the complete result — content.js's
    // own spontaneous mediaPresence message still arrives too; this is a backstop
    await Promise.allSettled(tabs.map((tab) => reportTabState(tab.id, tab.url)));
    console.log(`[MediaCtrl] reinjectAllTabs: done, tabMediaMap now has ${tabMediaMap.size} entr${tabMediaMap.size === 1 ? "y" : "ies"}`, Array.from(tabMediaMap.entries()));
    pushPlayableTabs();
}

async function reportTabState(tabId, url, attempt = 1) {
    try {
        // allFrames: true, matching manifest.json — some sites (cycani.org)
        // put the real <video> in a cross-origin iframe invisible to a
        // top-frame-only injection.
        await chrome.scripting.executeScript({
            target: { tabId, allFrames: true },
            files: ["content.js"],
        });
    } catch (e) {
        // not injectable (chrome://, PDFs, etc.) — skip silently
        console.log(`[MediaCtrl] tab ${tabId} (${url}): executeScript failed — ${e.message}`);
        return;
    }

    try {
        // frameId 0 = top frame. hasMedia/cor5Href are top-frame-only
        // concerns; without pinning to frameId 0, sendMessage would resolve
        // to whichever frame answers first, possibly a subframe reporting
        // hasMedia:false. A subframe with the real <video> reports itself
        // separately via its own "frameHasVideo" push.
        const response = await chrome.tabs.sendMessage(tabId, { command: "reportState" }, { frameId: 0 });
        console.log(`[MediaCtrl] tab ${tabId} (${url}): reportState ->`, response);
        if (response?.hasMedia) tabMediaMap.set(tabId, url);
        else tabMediaMap.delete(tabId);
    } catch (e) {
        // script injected fine but didn't answer in time — backgrounded/
        // throttled/just-discarded tabs racing the reconnect. Retry rather
        // than silently dropping the tab from playableTabs.
        console.log(`[MediaCtrl] tab ${tabId} (${url}): sendMessage failed on attempt ${attempt} — ${e.message}`);
        if (attempt < 3) {
            await new Promise((resolve) => setTimeout(resolve, 300));
            return reportTabState(tabId, url, attempt + 1);
        }
        console.warn(`[MediaCtrl] tab ${tabId} (${url}): gave up after ${attempt} attempts`);
        // leave any existing tabMediaMap entry untouched rather than guessing
    }
}

// ── Service worker keepalive / watchdog ───────────────────────────────────────
// Chrome kills this worker after ~30s idle, and an idle WebSocket doesn't
// count as activity — so the worker (and its reconnect timer) can die
// mid-session with no chance to recover on its own.
//
// chrome.alarms survives worker termination and wakes it on schedule. 30s is
// the minimum period Chrome allows.
const HEARTBEAT_ALARM = "mediactrl-heartbeat";
chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });

chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== HEARTBEAT_ALARM) return;

    if (!ws || ws.readyState === WebSocket.CLOSED) {
        // down (or fresh worker) — reconnect. onopen reinjects content
        // scripts into every tab, repairing state lost with the prior worker.
        connect();
    } else if (ws.readyState === WebSocket.OPEN) {
        // readyState alone isn't trustworthy — a bridge-side hang or
        // half-torn-down loopback socket can stay stuck at OPEN with no
        // close/error ever firing. Require a pong within 2 missed intervals
        // (90s) before trusting it.
        if (Date.now() - lastPongAt > 90000) {
            console.warn("[MediaCtrl] No pong in 90s — connection looks dead, forcing reconnect");
            try { ws.close(); } catch (e) {}
        } else {
            try { ws.send(JSON.stringify({ ping: Date.now() })); } catch (e) {}
        }
    }
});

connect();
