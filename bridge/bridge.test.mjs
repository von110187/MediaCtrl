import test from "node:test";
import assert from "node:assert";
import WS from "ws";
import { startBridge } from "./bridge.js";

const TOKEN = "t".repeat(32);
const EXT_ORIGIN = "chrome-extension://abcdefghijklmnop";

// A client that queues every message it receives, so tests can wait for one.
function client(port, { origin } = {}) {
    const url = `ws://127.0.0.1:${port}/`;
    // only the ws package can set Origin; AHK-role clients use Node's own WebSocket
    const ws = origin ? new WS(url, { headers: { origin } }) : new WebSocket(url);
    const queue = [];
    const waiters = [];
    let closed = false;
    const closeWaiters = [];
    ws.addEventListener("message", (e) => {
        const msg = JSON.parse(e.data);
        const i = waiters.findIndex((w) => w.type === msg.type);
        if (i >= 0) waiters.splice(i, 1)[0].resolve(msg);
        else queue.push(msg);
    });
    ws.addEventListener("close", () => {
        closed = true;
        closeWaiters.splice(0).forEach((r) => r());
    });
    const opened = new Promise((resolve) => ws.addEventListener("open", resolve));
    return {
        ws, queue, opened,
        send: (obj) => ws.send(JSON.stringify(obj)),
        next(type, ms = 1000) {
            const i = queue.findIndex((m) => m.type === type);
            if (i >= 0) return Promise.resolve(queue.splice(i, 1)[0]);
            return new Promise((resolve, reject) => {
                const w = { type, resolve };
                waiters.push(w);
                setTimeout(() => {
                    const j = waiters.indexOf(w);
                    if (j >= 0) { waiters.splice(j, 1); reject(new Error(`no ${type} within ${ms} ms`)); }
                }, ms);
            });
        },
        closed(ms = 1000) {
            if (closed) return Promise.resolve();
            return new Promise((resolve, reject) => {
                closeWaiters.push(resolve);
                setTimeout(() => reject(new Error(`not closed within ${ms} ms`)), ms);
            });
        },
        isClosed: () => closed,
        close: () => ws.close(),
    };
}

async function ahk(port) {
    const c = client(port);
    await c.opened;
    c.send({ type: "hello", role: "ahk", token: TOKEN });
    await c.next("extConnected");  // initial status
    return c;
}

async function extension(port) {
    const c = client(port, { origin: EXT_ORIGIN });
    await c.opened;
    c.send({ type: "hello", role: "extension", token: TOKEN });
    return c;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function withBridge(fn) {
    const bridge = await startBridge({ port: 0, token: TOKEN, aliveMs: 300 });
    try { await fn(bridge.port); } finally { await bridge.close(); }
}

test("wrong token is closed", () => withBridge(async (port) => {
    const c = client(port);
    await c.opened;
    c.send({ type: "hello", role: "ahk", token: "x".repeat(32) });
    await c.closed();
}));

test("extension without chrome-extension origin is closed", () => withBridge(async (port) => {
    const c = client(port, { origin: "https://evil.example" });
    await c.opened;
    c.send({ type: "hello", role: "extension", token: TOKEN });
    await c.closed();
}));

test("relays extension state to ahk without token", () => withBridge(async (port) => {
    const a = await ahk(port);
    const e = await extension(port);
    await a.next("extConnected");
    e.send({ type: "state", site: "youtube", playing: true, token: TOKEN });
    const msg = await a.next("state");
    assert.strictEqual(msg.site, "youtube");
    assert.strictEqual(msg.playing, true);
    assert.ok(!("token" in msg));
    a.close(); e.close();
}));

test("relays ahk command to extension", () => withBridge(async (port) => {
    const a = await ahk(port);
    const e = await extension(port);
    await a.next("extConnected");
    a.send({ type: "seek", by: 87, token: TOKEN });
    const msg = await e.next("seek");
    assert.strictEqual(msg.by, 87);
    assert.ok(!("token" in msg));
    a.close(); e.close();
}));

test("config from ahk is sent to a new extension", () => withBridge(async (port) => {
    const a = await ahk(port);
    a.send({ type: "config", sites: { youtube: { match: "youtube.com" } } });
    await sleep(50);
    const e = await extension(port);
    const msg = await e.next("config");
    assert.deepStrictEqual(msg.sites, { youtube: { match: "youtube.com" } });
    a.close(); e.close();
}));

test("second extension rejected while first alive", () => withBridge(async (port) => {
    const a = await ahk(port);
    const e1 = await extension(port);
    await a.next("extConnected");
    const e2 = await extension(port);
    await e2.closed();
    // the first one still relays
    e1.send({ type: "state", site: "bilibili" });
    assert.strictEqual((await a.next("state")).site, "bilibili");
    assert.ok(!e1.isClosed());
    a.close(); e1.close();
}));

test("second extension accepted after first goes quiet", () => withBridge(async (port) => {
    const a = await ahk(port);
    const e1 = await extension(port);
    await a.next("extConnected");
    await sleep(400);  // longer than aliveMs, e1 sends nothing
    const e2 = await extension(port);
    e2.send({ type: "state", site: "douyin" });
    assert.strictEqual((await a.next("state")).site, "douyin");
    assert.ok(!e2.isClosed());
    a.close(); e1.close(); e2.close();
}));

test("ahk is told when extension connects and disconnects", () => withBridge(async (port) => {
    const c = client(port);
    await c.opened;
    c.send({ type: "hello", role: "ahk", token: TOKEN });
    assert.strictEqual((await c.next("extConnected")).connected, false);
    const e = await extension(port);
    assert.strictEqual((await c.next("extConnected")).connected, true);
    e.close();
    assert.strictEqual((await c.next("extConnected")).connected, false);
    c.close();
}));
