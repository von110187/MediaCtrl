// ── WebSocket to the MediaCtrl bridge (bridge/bridge.js) ─────────────────────
// Only the active tab of the focused Chrome window talks to AHK: its state is
// forwarded, and every command is routed to it.
// The bridge routes per client, so (unlike the Mac's hs.httpserver) another
// local client can't take over this channel; there is no push counting.

let ws = null;
let token = "";
let port = 9224;
let reconnTimer = null;
let pingTimer = null;
let lastPongAt = 0;
const PING_MS = 2000;

// tabId of the active tab in the last-focused normal window. Chrome losing
// focus to another app (WINDOW_ID_NONE) keeps the last value.
let activeTabId = null;

function isOpen() {
    return ws && ws.readyState === WebSocket.OPEN;
}

// the token goes only in hello; the bridge knows this socket after that
function send(msg) {
    if (isOpen()) ws.send(JSON.stringify(msg));
}

function connect() {
    if (reconnTimer) { clearTimeout(reconnTimer); reconnTimer = null; }
    if (!token) return;  // token.json missing — AHK writes it on startup
    if (ws && ws.readyState !== WebSocket.CLOSED) return;

    lastPongAt = Date.now();
    ws = new WebSocket(`ws://127.0.0.1:${port}/`);

    ws.onopen = () => {
        send({ type: "hello", role: "extension", token, version: chrome.runtime.getManifest().version });
        refreshActiveTab().then(askActiveTabForState);
        // a message every 2 s keeps this service worker alive (Chrome 116+)
        // and keeps the bridge's "alive" window fresh
        clearInterval(pingTimer);
        pingTimer = setInterval(() => send({ type: "ping" }), PING_MS);
    };

    ws.onmessage = (event) => {
        let msg;
        try { msg = JSON.parse(event.data); } catch (e) { return; }

        if (msg.type === "pong") {
            lastPongAt = Date.now();
        } else if (msg.type === "config") {
            // content scripts read sites from storage, so a site change in
            // Config.ahk reaches every tab without re-injecting
            chrome.storage.local.set({ sites: msg.sites });
        } else if (msg.type === "refresh") {
            // AHK saw a different Chrome window take focus — don't rely on
            // windows.onFocusChanged alone, it doesn't always fire
            refreshActiveTab().then(askActiveTabForState);
        } else if (activeTabId !== null) {
            chrome.tabs.sendMessage(activeTabId, msg).catch(() => {});
        }
    };

    ws.onclose = () => {
        clearInterval(pingTimer);
        reconnTimer = setTimeout(() => loadSettingsAndConnect(false), 2000);
    };
    ws.onerror = () => { try { ws.close(); } catch (e) {} };
}

// ── Active tab tracking ───────────────────────────────────────────────────────

async function refreshActiveTab() {
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (tab) activeTabId = tab.id;
    log("active tab " + (tab ? tab.id + " " + (tab.url || "").slice(0, 40) : "none"));
}

// debug lines show up in AHK's State.bridgeLog (F6 tooltip)
function log(text) {
    send({ type: "log", text });
}

function askActiveTabForState() {
    if (activeTabId === null) return;
    chrome.tabs.sendMessage(activeTabId, { type: "reportNow" }).catch(() => {
        // no content script (chrome:// page, new tab) — tell AHK there's
        // nothing to watch here
        send({ type: "state", url: "", site: null, playable: false, playing: false,
               ready: false, isFullscreen: false, editableFocused: false, pageId: "none" });
    });
}

chrome.tabs.onActivated.addListener(async ({ tabId, windowId }) => {
    const win = await chrome.windows.getLastFocused().catch(() => null);
    if (win && win.id !== windowId) return;  // a background window switched tabs
    activeTabId = tabId;
    askActiveTabForState();
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
    if (windowId === chrome.windows.WINDOW_ID_NONE) return;
    const [tab] = await chrome.tabs.query({ active: true, windowId });
    if (tab) {
        activeTabId = tab.id;
        askActiveTabForState();
    }
});

chrome.tabs.onRemoved.addListener((tabId) => {
    if (tabId === activeTabId) activeTabId = null;
});

// ── Content script → AHK ─────────────────────────────────────────────────────

const FORWARDED = new Set(["state", "videoClick", "armed", "enterFailed", "probeResult"]);

chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!sender.tab || sender.frameId !== 0) return;
    if (sender.tab.id !== activeTabId) return;  // only the watched tab speaks
    if (FORWARDED.has(msg.type)) send(msg);
});

// ── Config + keepalive ────────────────────────────────────────────────────────
// AHK writes Extension/token.json (gitignored) on startup. Web pages can't
// read it — it isn't listed in web_accessible_resources — so the token stays
// between this extension, the bridge and AHK.

async function loadSettingsAndConnect(forceReconnect) {
    try {
        const res = await fetch(chrome.runtime.getURL("token.json"), { cache: "no-store" });
        const s = await res.json();
        const changed = s.token !== token || (s.port || 9224) !== port;
        token = s.token || "";
        port = s.port || 9224;
        if ((forceReconnect || changed) && ws) {
            ws.onclose = null;
            try { ws.close(); } catch (e) {}
            ws = null;
        }
    } catch (e) {
        token = "";
    }
    connect();
}

// chrome.alarms survives service-worker termination and wakes it up — the
// backstop if the worker was killed while disconnected
const HEARTBEAT_ALARM = "mediactrl-heartbeat";
chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== HEARTBEAT_ALARM) return;
    if (!ws || ws.readyState === WebSocket.CLOSED) {
        // re-reads token.json too, so a new token is picked up within 30 s
        loadSettingsAndConnect(false);
    } else if (isOpen() && Date.now() - lastPongAt > 60000) {
        // stuck at OPEN with no pongs — force a reconnect
        try { ws.close(); } catch (e) {}
    }
});

loadSettingsAndConnect(false);
