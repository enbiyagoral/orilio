// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

// Run with: node --test Tests/Extension/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const read = (name) => readFileSync(new URL(`../../extensions/chrome/${name}`, import.meta.url), "utf8");
const background = read("background.js");
const policy = read("policy.js");

const event = () => {
  const listeners = [];
  return { addListener: (fn) => listeners.push(fn), fire: (...args) => listeners.forEach((fn) => fn(...args)) };
};

/** The service worker with a fake chrome: a native port and music-tab ports to watch. */
function worker() {
  const sentNative = [];
  const native = { onMessage: event(), onDisconnect: event(), postMessage: (m) => sentNative.push(m), disconnect() {} };
  const focused = [];
  const onConnect = event();
  const chrome = {
    storage: { session: { get: async () => ({ browserId: "b1" }), set: async () => {} } },
    runtime: { onConnect, onInstalled: event(), connectNative: () => native, getManifest: () => ({ version: "1" }), lastError: null },
    tabs: { onAttached: event(), update: async (id) => { focused.push(id); return { windowId: 7 }; }, query: async () => [] },
    windows: { update: async () => {} },
    scripting: { executeScript: async () => {} },
  };
  const context = { chrome, navigator: {}, crypto: globalThis.crypto, console, setTimeout, clearTimeout };
  context.globalThis = context;
  context.importScripts = () => vm.runInContext(policy, context);
  vm.createContext(context);
  vm.runInContext(background, context);
  const tab = (id, url = "https://music.youtube.com/watch") => {
    const received = [];
    const port = { name: "orilio-media", sender: { tab: { id, windowId: 1 }, url }, onMessage: event(), onDisconnect: event(),
                   postMessage: (m) => received.push(m), disconnect: () => received.push("disconnected") };
    onConnect.fire(port);
    return { port, received };
  };
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  return { sentNative, native, focused, tab, settle };
}

test("a command reaches only its own tab; a gone tab is answered", async () => {
  const w = worker();
  const a = w.tab(11), b = w.tab(12);
  w.native.onMessage.fire({ v: 1, type: "command", id: "c1", tabId: 11, command: "pause" });
  await w.settle();
  assert.deepEqual(a.received.map((m) => m.command), ["pause"]);
  assert.equal(b.received.length, 0);
  w.native.onMessage.fire({ v: 1, type: "command", id: "c2", tabId: 99, command: "play" });
  await w.settle();
  assert.ok(w.sentNative.some((m) => m.type === "result" && m.id === "c2" && m.ok === false && m.error === "tab-gone"));
});

test("focus is done by the worker, not sent to the page", async () => {
  const w = worker();
  const a = w.tab(21);
  w.native.onMessage.fire({ v: 1, type: "command", id: "f", tabId: 21, command: "focus" });
  await w.settle(); await w.settle();
  assert.deepEqual(w.focused, [21]);
  assert.equal(a.received.length, 0);
  assert.ok(w.sentNative.some((m) => m.type === "result" && m.id === "f" && m.ok === true));
});

test("other protocol versions and pages that aren't music sites are ignored", async () => {
  const w = worker();
  const a = w.tab(31);
  w.native.onMessage.fire({ v: 2, type: "command", id: "x", tabId: 31, command: "pause" });
  await w.settle();
  assert.equal(a.received.length, 0);
  const other = w.tab(32, "https://example.com/");
  assert.deepEqual(other.received, ["disconnected"]);
});

test("hello names the browser, and a tab's sessions are relayed with its id", async () => {
  const w = worker();
  const a = w.tab(41);
  a.port.onMessage.fire({ type: "session", title: "Song" });
  await w.settle();
  assert.equal(w.sentNative[0].type, "hello");
  assert.ok(w.sentNative.some((m) => m.type === "session" && m.tabId === 41 && m.browser === "b1"));
  a.port.onDisconnect.fire();
  await w.settle();
  assert.ok(w.sentNative.some((m) => m.type === "removed" && m.tabId === 41));
});
