; ============ BRIDGE CLIENT ============
; This script's WebSocket to bridge/bridge.js (Lib/WebSocket.ahk, async mode,
; so receiving never blocks the AHK thread). Sends hello {role: "ahk", token},
; pings every 1 s, and reconnects 2 s after any close. A bridge that died is
; only noticed when a send fails (WinHTTP doesn't report the aborted read), so
; the ping interval is what bounds recovery: about 3 s after a bridge restart.
; Incoming messages go to OnBridgeMessage(msg) as plain objects (true/false
; arrive as 1/0, null as "").

#include Lib/WebSocket.ahk
#include Lib/JSON.ahk

BRIDGE_PING_MS      := 1000
BRIDGE_RECONNECT_MS := 2000
BRIDGE_SILENT_MS    := 7000   ; no frame from the bridge this long — reconnect

_bridgeWs           := ""
_bridgeExtConnected := false
_bridgeLastHeardAt  := 0

; WebSocket.onError throws for anything but "connection aborted"; for us every
; error just means the socket is gone
class _BridgeSocket extends WebSocket {
    onError(err, what := 0) {
        if this.readyState == 3
            return
        this.readyState := 3
        try this.onClose(1006, "")
    }
}

BridgeClient_Connect() {
    global CONFIG, _bridgeWs, _bridgeExtConnected, _bridgeLastHeardAt
    SetTimer(BridgeClient_Connect, 0)
    _bridgeExtConnected := false
    _bridgeWs := ""  ; __Delete closes the old handles
    try {
        _bridgeWs := _BridgeSocket("ws://127.0.0.1:" . CONFIG.BRIDGE_PORT . "/", {
            message: _BridgeClient_OnText,
            close:   _BridgeClient_OnClose,
        })
    } catch {
        _bridgeWs := ""
        SetTimer(BridgeClient_Connect, -BRIDGE_RECONNECT_MS)  ; bridge not up yet
        return
    }
    _bridgeLastHeardAt := A_TickCount
    BridgeClient_Send({type: "hello", role: "ahk", token: Bridge_Token()})
    SetTimer(_BridgeClient_Ping, BRIDGE_PING_MS)
}

; JSON-encodes and sends; a no-op while not connected
BridgeClient_Send(obj) {
    global _bridgeWs
    if !_BridgeClient_Open()
        return
    try _bridgeWs.sendText(JSON.stringify(obj, 0))
}

; our socket is open and the bridge says the extension is connected
BridgeClient_Connected() {
    global _bridgeExtConnected
    return _BridgeClient_Open() && _bridgeExtConnected
}

_BridgeClient_Open() {
    global _bridgeWs
    return _bridgeWs != "" && _bridgeWs.readyState == 1
}

_BridgeClient_OnText(self, text) {
    global _bridgeExtConnected, _bridgeLastHeardAt
    if self != _bridgeWs
        return
    _bridgeLastHeardAt := A_TickCount
    try msg := JSON.parse(text, false, false)
    catch
        return
    if !IsObject(msg) || !msg.HasOwnProp("type")
        return
    if msg.type == "extConnected"
        _bridgeExtConnected := msg.HasOwnProp("connected") && msg.connected
    OnBridgeMessage(msg)
}

_BridgeClient_OnClose(self, status, reason) {
    global _bridgeWs, _bridgeExtConnected
    if self != _bridgeWs
        return
    _bridgeExtConnected := false
    SetTimer(_BridgeClient_Ping, 0)
    ; reconnect from a fresh thread, not from inside the socket's own callback
    SetTimer(BridgeClient_Connect, -BRIDGE_RECONNECT_MS)
}

_BridgeClient_Ping() {
    global _bridgeWs, _bridgeLastHeardAt
    if !_BridgeClient_Open() || A_TickCount - _bridgeLastHeardAt > BRIDGE_SILENT_MS {
        try _bridgeWs.shutdown()
        _BridgeClient_OnClose(_bridgeWs, 1006, "silent")
        return
    }
    BridgeClient_Send({type: "ping"})
}
