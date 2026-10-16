; ============ BRIDGE SERVER ============
; Starts the Node relay (bridge/bridge.js) that carries JSON between this
; script and the Chrome extension over WebSockets on 127.0.0.1:9224, and
; owns the shared token both sides must present. Talking to the bridge is
; BridgeClient.ahk's job.

; 32 hex chars, created once and kept next to the script (gitignored)
Bridge_Token() {
    static token := ""
    if token != ""
        return token
    path := A_ScriptDir . "\mediactrl_token.txt"
    try token := Trim(FileRead(path))
    if !RegExMatch(token, "^[0-9a-f]{32}$") {
        buf := Buffer(16)
        DllCall("bcrypt\BCryptGenRandom", "ptr", 0, "ptr", buf, "uint", 16, "uint", 2)  ; system RNG
        token := ""
        Loop 16
            token .= Format("{:02x}", NumGet(buf, A_Index - 1, "uchar"))
        FileOpen(path, "w", "UTF-8-RAW").Write(token)
    }
    return token
}

; The extension reads Extension\token.json (gitignored). It isn't web
; accessible, so only the extension itself can fetch it.
Bridge_WriteExtensionToken() {
    global CONFIG
    FileOpen(A_ScriptDir . "\Extension\token.json", "w", "UTF-8-RAW")
        .Write('{"token": "' . Bridge_Token() . '", "port": ' . CONFIG.BRIDGE_PORT . '}')
}

Bridge_Start() {
    global CONFIG
    Bridge_KillAll()

    bridgeDir := A_ScriptDir . "\bridge"
    if !DirExist(bridgeDir . "\node_modules\ws") {
        ToolTip("📦 Installing bridge packages...")
        RunWait(A_ComSpec . ' /c npm install --no-audit --no-fund', bridgeDir, "Hide")
        ToolTip()
    }

    ; the token goes to the child through its environment, not its command line
    EnvSet("MEDIACTRL_TOKEN", Bridge_Token())
    EnvSet("MEDIACTRL_PORT", CONFIG.BRIDGE_PORT)
    Run('node "' . bridgeDir . '\bridge.js"', bridgeDir, "Hide")
    EnvSet("MEDIACTRL_TOKEN")
}

; Closes only node processes running our bridge — never other node.exe.
; mediactrl_bridge.js is the pre-port generated bridge, killed so it can't
; keep holding the port after an update. Returns how many were closed.
Bridge_KillAll() {
    closed := 0
    try {
        rows := ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='node.exe'")
        for row in rows {
            cmd := row.CommandLine
            if !cmd  ; unreadable (no rights) — not ours to touch
                continue
            if InStr(cmd, "bridge\bridge.js") || InStr(cmd, "mediactrl_bridge.js") {
                ProcessClose(row.ProcessId)
                ProcessWaitClose(row.ProcessId, 2)
                closed += 1
            }
        }
    }
    return closed
}
