; ============ BRIDGE SERVER ============
; Runs a local Node.js server:
;   WS  port 9224 — Chrome extension pushes URL + playable tabs
;   HTTP port 9223 — AHK sends commands to extension (speed, cor5, etc.)
;
; mediactrl_bridge.js and node_modules live next to the script (A_ScriptDir)
; so they survive OS temp-folder cleanup between runs.
; Runtime IPC files (url, tabs, cor5) stay in A_Temp — they are throwaway.

KillPort(port) {
    batFile := A_Temp . "\kill_port_" . port . ".bat"
    if FileExist(batFile)
        FileDelete(batFile)
    q := Chr(34)
    content := "@echo off`n"
    content .= "for /f " . q . "tokens=5" . q . " %a in ('netstat -aon ^| find " . q . port . q . "') do taskkill /f /pid %a"
    FileOpen(batFile, "w").Write(content)
    shell := ComObject("WScript.Shell")
    shell.Run 'cmd /c "' . batFile . '"', 0, true
    Sleep(400)
}

StartBridgeServer() {
    KillPort("9223")
    KillPort("9224")
    Sleep(400)

    nodeScript := A_ScriptDir . "\mediactrl_bridge.js"
    if FileExist(nodeScript)
        FileDelete(nodeScript)

    FileAppend '
(
const http = require("http");
const fs   = require("fs");
const path = require("path");
const { WebSocketServer } = require("ws");

const URL_FILE        = path.join(require("os").tmpdir(), "ahk_current_url.txt");
const TABS_FILE       = path.join(require("os").tmpdir(), "ahk_playing_tabs.txt");
const COR5_FILE       = path.join(require("os").tmpdir(), "ahk_cor5_href.txt");
const DEBUG_LOG_FILE  = path.join(require("os").tmpdir(), "ahk_bridge_debug.log");
const PID_FILE        = path.join(require("os").tmpdir(), "ahk_bridge_pid.txt");
const BRIDGE_VERSION  = "sync-writes-v2";

let currentUrl  = "";
let playingTabs = [];
let wsClient    = null;

// Append-only (never truncated) on purpose: if a stale old-code process is
// still alive alongside a freshly started one, both will log to this same
// file with their own PIDs, making that overlap directly visible instead of
// guessed at.
function dlog(msg) {
    try {
        fs.appendFileSync(DEBUG_LOG_FILE, "[" + new Date().toISOString() + "] [pid " + process.pid + "] " + msg + "\n");
    } catch (e) {}
}

// Overwritten every startup — whatever PID is in this file right now is the
// most recently started bridge. Compare against Task Manager's node.exe list:
// if there's more than one node.exe and it's not this PID, that's a stale
// leftover process still serving the OLD code on the same port.
try { fs.writeFileSync(PID_FILE, "pid=" + process.pid + " version=" + BRIDGE_VERSION + " startedAt=" + new Date().toISOString()); } catch (e) {}
dlog("=== bridge starting, version=" + BRIDGE_VERSION + " ===");

// HTTP server — AHK sends commands via /setcommand/<cmd>
const server = http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");

    if (req.method === "OPTIONS") { res.writeHead(200); res.end(); return; }

    if (req.url.startsWith("/setcommand/")) {
        const command = req.url.replace("/setcommand/", "");
        if (command.startsWith("navigate_")) {
            const url = decodeURIComponent(command.replace("navigate_", ""));
            sendToExtension({ navigate: url });
        } else {
            sendToExtension({ command });
        }
        res.writeHead(200); res.end("ok");
    } else {
        res.writeHead(404); res.end();
    }
});

// WebSocket server — Chrome extension connects here
const wss = new WebSocketServer({ port: 9224, host: "127.0.0.1" });

wss.on("connection", (ws) => {
    dlog("client connected");
    // If a previous connection is still hanging around (e.g. the extension's
    // old service-worker instance never cleanly closed its socket before a
    // new one connected), kill it outright so it can't linger as a zombie
    // that still LOOKS connected but never actually delivers data again.
    if (wsClient && wsClient !== ws) {
        dlog("closing stale prior connection");
        try { wsClient.terminate(); } catch (e) {}
    }
    wsClient = ws;
    ws.on("message", (msg) => {
        try {
            const data = JSON.parse(msg);
            // Synchronous writes are deliberate here: fs.writeFile's async
            // callback gives no guarantee that overlapping writes to the same
            // file complete in the order they were issued (Node's thread pool
            // can finish a later write before an earlier one). When two pushes
            // land close together (e.g. two tabs reporting in within
            // milliseconds of each other), that race could let a stale,
            // smaller snapshot clobber a newer, larger one on disk. These
            // payloads are a few hundred bytes at most, so blocking briefly
            // here is cheap and removes the race entirely.
            if (data.url !== undefined) {
                currentUrl = data.url;
                try { fs.writeFileSync(URL_FILE, currentUrl); } catch (e) {}
            }
            if (data.playingTabs) {
                dlog("received playingTabs (" + data.playingTabs.length + "): " + JSON.stringify(data.playingTabs));
                playingTabs = data.playingTabs;
                try {
                    fs.writeFileSync(TABS_FILE, playingTabs.join("\n"));
                    dlog("wrote " + playingTabs.length + " tab(s) to " + TABS_FILE);
                } catch (e) {
                    dlog("writeFileSync FAILED: " + e.message);
                }
            }
            if ("cor5Href" in data) {
                try { fs.writeFileSync(COR5_FILE, data.cor5Href || ""); } catch (e) {}
            }
            if (data.ping !== undefined) {
                try { ws.send(JSON.stringify({ pong: data.ping })); } catch (e) {}
            }
        } catch(e) {
            dlog("message handler error: " + e.message);
        }
    });
    ws.on("close", () => { dlog("client disconnected"); if (wsClient === ws) wsClient = null; });
});

function sendToExtension(payload) {
    if (wsClient && wsClient.readyState === 1)
        wsClient.send(JSON.stringify(typeof payload === "string" ? { command: payload } : payload));
}

server.listen(9223, "127.0.0.1");
)', nodeScript

    if !DirExist(A_ScriptDir . "\node_modules\ws") {
        ToolTip("📦 Installing ws package...")
        wsShell := ComObject("WScript.Shell")
        wsShell.Run 'cmd /c cd "' . A_ScriptDir . '" && npm install ws', 0, true
        ToolTip()
    }

    Run('node "' . nodeScript . '"',, "Hide")
    Sleep(1000)
}

SendCommand(cmd) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", "http://127.0.0.1:9223/setcommand/" . cmd, false)
        http.Send()
    } catch {
    }
}
