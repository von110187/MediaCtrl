// ── WebSocket to AHK bridge ───────────────────────────────────────────────────
const WS_URL = "ws://127.0.0.1:9224";

let ws          = null;
let reconnTimer = null;

// tabId → url, for tabs that have a media element
const tabMediaMap = new Map();

function connect() {
    if (reconnTimer) { clearTimeout(reconnTimer); reconnTimer = null; }

    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
        console.log("[MediaCtrl] Connected to AHK bridge");
        // Don't call pushPlayableTabs() here — tabMediaMap is freshly empty
        // after any service-worker restart, and pushing it now would overwrite
        // AHK's last-known-good state with an empty list before the reinjected
        // tabs below have had a chance to report back in. Each tab's own
        // mediaPresence message (sent from content.js's "already injected"
        // branch) calls pushPlayableTabs() itself once it arrives, so the
        // list rebuilds correctly without ever going through a false-empty state.
        reinjectAllTabs();
        pushCurrentTab();
    };

    ws.onmessage = async (event) => {
        try {
            const data = JSON.parse(event.data);
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
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const entries = Array.from(tabMediaMap.entries()).map(([tabId, url]) => tabId + "|" + url);
    ws.send(JSON.stringify({ playingTabs: entries }));
}

// ── Startup injection ─────────────────────────────────────────────────────────
// Re-inject content.js into all existing http tabs when the bridge connects.
// This recovers playable tab state after an AHK reload without needing manual refreshes.

async function reinjectAllTabs() {
    const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
    for (const tab of tabs) {
        try {
            await chrome.scripting.executeScript({
                target: { tabId: tab.id, allFrames: false },
                files: ["content.js"],
            });
        } catch (e) {
            // Tab may not be injectable (e.g. chrome:// pages, PDFs) — skip silently
        }
    }
}

// ── Service worker keepalive / watchdog ───────────────────────────────────────
// Chrome can terminate this service worker after ~30s of inactivity. An idle
// WebSocket (no traffic in either direction — e.g. just watching one video with
// no tab switches or DOM changes) doesn't count as activity, so the worker can
// die mid-session, silently dropping the connection to AHK. setTimeout-based
// reconnect (ws.onclose above) only works if the worker is still alive to run
// it — if Chrome already killed it, that timer dies too and nothing reconnects
// until some unrelated tab event happens to wake the worker back up.
//
// chrome.alarms is the sanctioned fix: alarms survive worker termination and
// will wake the worker on schedule to re-run this handler, regardless of
// whether anything else happened. 30s is the minimum period Chrome allows.
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
        // Send a tiny ping. Per Chrome's WebSocket service-worker lifetime
        // extension (Chrome 116+), any traffic on the socket resets the 30s
        // idle timer — so this keeps the worker (and the connection) alive
        // through quiet stretches instead of waiting to die and reconnect.
        try { ws.send(JSON.stringify({ ping: Date.now() })); } catch (e) {}
    }
});

connect();
