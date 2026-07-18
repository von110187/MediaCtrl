; ============ BRIDGE SERVER ============
; Local Node.js server: WS port 9224 (extension pushes URL/tabs), HTTP port
; 9223 (AHK sends commands to extension). Script + node_modules live next to
; the script (A_ScriptDir) so they survive temp-folder cleanup; runtime IPC
; files stay in A_Temp and are throwaway.

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
const EXT_PLAYING_FILE = path.join(require("os").tmpdir(), "ahk_ext_playing.txt");
const VIDEO_CLICK_FILE = path.join(require("os").tmpdir(), "ahk_video_click.txt");
const DEBUG_LOG_FILE  = path.join(require("os").tmpdir(), "ahk_bridge_debug.log");
const PID_FILE        = path.join(require("os").tmpdir(), "ahk_bridge_pid.txt");
const BRIDGE_VERSION  = "sync-writes-v3";

let currentUrl  = "";
let playingTabs = [];
let wsClient    = null;

// append-only so overlapping stale/fresh process logs stay distinguishable by PID
function dlog(msg) {
    try {
        fs.appendFileSync(DEBUG_LOG_FILE, "[" + new Date().toISOString() + "] [pid " + process.pid + "] " + msg + "\n");
    } catch (e) {}
}

// most-recently-started PID — a different node.exe in Task Manager is a stale process on the same port
try { fs.writeFileSync(PID_FILE, "pid=" + process.pid + " version=" + BRIDGE_VERSION + " startedAt=" + new Date().toISOString()); } catch (e) {}
dlog("=== bridge starting, version=" + BRIDGE_VERSION + " ===");

// AHK sends commands via /setcommand/<cmd>
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

// browser extension connects here
const wss = new WebSocketServer({ port: 9224, host: "127.0.0.1" });

wss.on("connection", (ws) => {
    dlog("client connected");
    // kill stale prior connection so it can't linger as a zombie (e.g. extension's old service-worker socket)
    if (wsClient && wsClient !== ws) {
        dlog("closing stale prior connection");
        try { wsClient.terminate(); } catch (e) {}
    }
    wsClient = ws;
    ws.on("message", (msg) => {
        try {
            const data = JSON.parse(msg);
            // sync writes: avoids ordering issues between overlapping async writes; payloads are tiny
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
            if ("extPlaying" in data) {
                try { fs.writeFileSync(EXT_PLAYING_FILE, data.extPlaying ? "1" : "0"); } catch (e) {}
            }
            if (data.videoClick) {
                try { fs.writeFileSync(VIDEO_CLICK_FILE, "1"); } catch (e) {}
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
