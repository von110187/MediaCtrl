// ============ MEDIACTRL BRIDGE ============
// Relays JSON between the Chrome extension and the AHK script over
// WebSockets on 127.0.0.1. Started (and killed) by Bridge.ahk.
//
// - Every client's first message is {type: "hello", role, token}. A wrong
//   token, an unknown role, or an extension client whose Origin isn't
//   chrome-extension:// closes the socket.
// - One client per role. While the current one is alive (any message within
//   aliveMs) a newcomer of that role is closed; once it goes quiet the
//   newcomer replaces it. Quiet clients are dropped.
// - Everything else is relayed extension <-> ahk unchanged, minus any token
//   field. No token is ever sent outward.
// - The latest config from ahk is kept and handed to each new extension.
// - ahk gets {type: "extConnected", connected} whenever the extension comes
//   or goes (and once right after its own hello).
// - ping gets pong.

import { WebSocketServer } from "ws";
import { timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";

const ROLES = ["extension", "ahk"];
const HELLO_TIMEOUT_MS = 5000;

function tokenMatches(given, token) {
    if (typeof given !== "string") return false;
    const a = Buffer.from(given), b = Buffer.from(token);
    return a.length === b.length && timingSafeEqual(a, b);
}

export function startBridge({ port, token, aliveMs = 5000 }) {
    if (!token || token.length < 32) throw new Error("bridge: token missing or too short");

    const wss = new WebSocketServer({ host: "127.0.0.1", port, maxPayload: 1 << 20 });
    const current = { extension: null, ahk: null };  // role -> { ws, lastAt }
    let config = null;

    const isOpen = (ws) => ws.readyState === ws.OPEN;
    const sendTo = (role, msg) => {
        const c = current[role];
        if (c && isOpen(c.ws)) c.ws.send(JSON.stringify(msg));
    };
    const extConnected = () => !!(current.extension && isOpen(current.extension.ws));
    const tellAhk = () => sendTo("ahk", { type: "extConnected", connected: extConnected() });

    wss.on("connection", (ws, req) => {
        let role = null;
        const helloTimer = setTimeout(() => ws.terminate(), HELLO_TIMEOUT_MS);

        ws.on("message", (raw, isBinary) => {
            let msg;
            try { msg = JSON.parse(raw.toString()); } catch { return; }
            if (isBinary || !msg || typeof msg !== "object" || Array.isArray(msg)) return;

            if (role === null) {
                const origin = req.headers.origin || "";
                const ok = msg.type === "hello" && ROLES.includes(msg.role) && tokenMatches(msg.token, token)
                    && (msg.role !== "extension" || origin.startsWith("chrome-extension://"));
                if (!ok) { ws.close(1008, "unauthorized"); return; }

                const holder = current[msg.role];
                if (holder && isOpen(holder.ws) && Date.now() - holder.lastAt < aliveMs) {
                    ws.close(1013, "another client of this role is connected");
                    return;
                }
                clearTimeout(helloTimer);
                role = msg.role;
                if (holder) holder.ws.terminate();
                current[role] = { ws, lastAt: Date.now() };

                if (role === "extension" && config) ws.send(JSON.stringify(config));
                tellAhk();
                return;
            }

            const me = current[role];
            if (!me || me.ws !== ws) { ws.terminate(); return; }  // replaced meanwhile
            me.lastAt = Date.now();

            if (msg.type === "ping") { ws.send(JSON.stringify({ type: "pong" })); return; }
            if (msg.type === "hello") return;

            const { token: _drop, ...clean } = msg;
            if (role === "ahk") {
                if (clean.type === "config") config = clean;
                sendTo("extension", clean);
            } else {
                sendTo("ahk", clean);
            }
        });

        ws.on("close", () => {
            clearTimeout(helloTimer);
            if (role && current[role] && current[role].ws === ws) {
                current[role] = null;
                if (role === "extension") tellAhk();
            }
        });
        ws.on("error", () => {});
    });

    // a client that stopped talking is gone, even if its socket never closed
    const sweep = setInterval(() => {
        for (const role of ROLES) {
            const c = current[role];
            if (c && Date.now() - c.lastAt >= aliveMs * 2) c.ws.terminate();
        }
    }, aliveMs);

    return new Promise((resolve, reject) => {
        wss.once("error", reject);
        wss.once("listening", () => {
            wss.off("error", reject);
            resolve({
                port: wss.address().port,
                close: () => new Promise((done) => {
                    clearInterval(sweep);
                    for (const c of wss.clients) c.terminate();
                    wss.close(() => done());
                }),
            });
        });
    });
}

// node bridge/bridge.js — token from MEDIACTRL_TOKEN, port from MEDIACTRL_PORT
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const port = Number(process.env.MEDIACTRL_PORT || 9224);
    startBridge({ port, token: process.env.MEDIACTRL_TOKEN || "" })
        .then((b) => console.log(`mediactrl bridge on 127.0.0.1:${b.port}`))
        .catch((e) => { console.error("mediactrl bridge:", e.message); process.exit(1); });
}
