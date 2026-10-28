// Run with: node --test Tests/Extension/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../../extensions/chrome/media-session-bridge.js", import.meta.url), "utf8");

/** A page with just enough of navigator.mediaSession and document for the bridge. */
function page() {
  const listeners = {};
  let writes = 0;
  const dataset = new Proxy({}, { set(target, key, value) { writes++; target[key] = value; return true; } });
  const registered = [];
  const context = {
    navigator: { mediaSession: { setActionHandler: (action, handler) => registered.push([action, handler]) } },
    document: {
      documentElement: { dataset },
      addEventListener: (type, fn) => { listeners[type] = fn; },
    },
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return {
    session: context.navigator.mediaSession,
    dataset,
    registered,
    writes: () => writes,
    request: (detail) => listeners["orilio:media-action"]({ detail }),
  };
}

test("captures handlers and still registers them with the browser", () => {
  const p = page();
  const calls = [];
  p.session.setActionHandler("nexttrack", (details) => calls.push(details));
  assert.equal(p.registered.length, 1); // the real API still gets the handler (media keys keep working)
  assert.equal(p.dataset.orilioActions, "nexttrack");
  p.request("nexttrack");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].action, "nexttrack"); // created in the page's realm, so compare fields
});

test("seekto passes a validated time", () => {
  const p = page();
  const calls = [];
  p.session.setActionHandler("seekto", (details) => calls.push(details.seekTime));
  p.request("seekto:42.5");
  p.request("seekto:-1");
  p.request("seekto:abc");
  assert.deepEqual(calls, [42.5]);
});

test("ignores unknown actions and non-string requests", () => {
  const p = page();
  const calls = [];
  p.session.setActionHandler("play", () => calls.push("play")); // not bridged
  p.request("play");
  p.request({ action: "nexttrack" });
  assert.deepEqual(calls, []);
  assert.equal(p.dataset.orilioActions ?? "", "");
});

test("removing a handler un-advertises it", () => {
  const p = page();
  p.session.setActionHandler("previoustrack", () => {});
  p.session.setActionHandler("previoustrack", null);
  assert.equal(p.dataset.orilioActions, "");
});

test("re-registering the same handlers does not rewrite the attribute", () => {
  const p = page();
  for (let i = 0; i < 50; i++) p.session.setActionHandler("nexttrack", () => {});
  assert.equal(p.writes(), 1);
});
