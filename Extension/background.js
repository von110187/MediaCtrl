// ── WebSocket to AHK bridge ───────────────────────────────────────────────────
const WS_URL = "ws://127.0.0.1:9224";

let ws          = null;
let reconnTimer = null;
let lastPongAt  = 0;

// tabId → url, for tabs that have a media element
const tabMediaMap = new Map();

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
                // For speed commands, send to all tabs with media so it works
                // even when the tab isn't detected as active (e.g. in fullscreen).
                // For other commands, fall back to the active tab.
                if (data.command.startsWith("speed_") && tabMediaMap.size > 0) {
                    for (const tabId of tabMediaMap.keys()) {
                        try {
                            await chrome.tabs.sendMessage(tabId, { command: data.command });
                        } catch (e) {}
                    }
                } else {
                    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
                    if (tab) {
                        try {
                            await chrome.tabs.sendMessage(tab.id, { command: data.command });
                        } catch (e) {}
                    }
                }
            }
        } catch (e) {}
    };

    ws.onclose = () => { reconnTimer = setTimeout(connect, 2000); };
    ws.onerror = () => { ws.close(); };
}

// ── Content script messages ───────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!sender.tab) return;
    const { id: tabId, url } = sender.tab;

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
    }
});

// ── Tab lifecycle ─────────────────────────────────────────────────────────────

chrome.tabs.onRemoved.addListener((tabId) => {
    if (tabMediaMap.has(tabId)) {
        tabMediaMap.delete(tabId);
        pushPlayableTabs();
    }
});

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
    // Don't eagerly remove from tabMediaMap on URL change — the content script
    // will report mediaPresence:false on the new page if there's no media.
    // Removing here causes a gap where the tab briefly disappears from playableTabs
    // during SPA navigations (e.g. YouTube) before the new page reports in.
    if (change.url || change.status === "complete")
        pushCurrentTab();
});

chrome.tabs.onActivated.addListener(pushCurrentTab);

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
        await chrome.scripting.executeScript({
            target: { tabId, allFrames: false },
            files: ["content.js"],
        });
    } catch (e) {
        // Tab may not be injectable (e.g. chrome:// pages, PDFs) — skip silently
        console.log(`[MediaCtrl] tab ${tabId} (${url}): executeScript failed — ${e.message}`);
        return;
    }

    try {
        const response = await chrome.tabs.sendMessage(tabId, { command: "reportState" });
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
