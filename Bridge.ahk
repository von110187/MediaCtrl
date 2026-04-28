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

let currentUrl  = "";
let playingTabs = [];
let wsClient    = null;

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
    wsClient = ws;
    ws.on("message", (msg) => {
        try {
            const data = JSON.parse(msg);
            if (data.url !== undefined) {
                currentUrl = data.url;
                fs.writeFile(URL_FILE, currentUrl, () => {});
            }
            if (data.playingTabs) {
                playingTabs = data.playingTabs;
                fs.writeFile(TABS_FILE, playingTabs.join("\n"), () => {});
            }
            if ("cor5Href" in data) {
                fs.writeFile(COR5_FILE, data.cor5Href || "", () => {});
            }
        } catch(e) {}
    });
    ws.on("close", () => wsClient = null);
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
