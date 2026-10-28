// Relays between music tabs (YouTube Music, Spotify, SoundCloud) and Orilio's native messaging host.
// The host is started by Chrome only while at least one music tab is connected,
// so the service worker can sleep when there is nothing to report.

importScripts("policy.js");

const HOST = "com.deaconcornsoft.orilio";
const PROTOCOL = 1;
const PORT_NAME = "orilio-media";
const ORIGINS = ["https://music.youtube.com", "https://open.spotify.com", "https://soundcloud.com",
                 "https://www.youtube.com", "https://youtube.com"];
const BROWSER_NAME = globalThis.OrilioPolicy.browserName(navigator.userAgentData?.brands);

// A random id for this running browser, kept for its session (survives worker restarts, not browser
// restarts). Orilio uses it to keep tab ids of two Chromium browsers apart.
let browserId = null;
const ready = chrome.storage.session.get("browserId").then(async ({ browserId: stored }) => {
  browserId = stored ?? crypto.randomUUID().replaceAll("-", "").slice(0, 16);
  if (!stored) await chrome.storage.session.set({ browserId });
});
const MAX_NATIVE_RETRIES = 6;

/** tabId -> { port, windowId, last } */
const tabs = new Map();
let native = null;
let nativeRetries = 0;
let nativeRetryTimer = null;

// Messages wait for the browser id, and keep their order while they wait.
function postNative(message) {
  ready.then(() => native?.postMessage({ v: PROTOCOL, browser: browserId, ...message }));
}

function connectNative() {
  if (native || tabs.size === 0) return;
  clearTimeout(nativeRetryTimer);
  try {
    native = chrome.runtime.connectNative(HOST);
  } catch (error) {
    console.warn("Orilio: cannot start native host", error);
    native = null;
    scheduleNativeRetry();
    return;
  }
  native.onMessage.addListener(onNativeMessage);
  native.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError?.message;
    if (reason) console.warn("Orilio: native host disconnected:", reason);
    native = null;
    scheduleNativeRetry();
  });
  postNative({ type: "hello", version: chrome.runtime.getManifest().version, browserName: BROWSER_NAME });
  for (const [tabId, entry] of tabs) if (entry.last) postNative({ ...entry.last, tabId, windowId: entry.windowId });
}

// Bounded exponential backoff: the host may be missing (not installed) or crashing.
function scheduleNativeRetry() {
  if (tabs.size === 0 || nativeRetries >= MAX_NATIVE_RETRIES) return;
  const delay = Math.min(30_000, 1_000 * 2 ** nativeRetries++);
  nativeRetryTimer = setTimeout(connectNative, delay);
}

async function focusTab(tabId) {
  const tab = await chrome.tabs.update(tabId, { active: true });
  await chrome.windows.update(tab.windowId, { focused: true });
}

async function onNativeMessage(message) {
  if (!message || message.v !== PROTOCOL) return;
  if (message.type === "resync") {
    for (const entry of tabs.values()) entry.port.postMessage({ type: "resync" });
    return;
  }
  if (message.type !== "command" || typeof message.id !== "string" || !Number.isInteger(message.tabId)) return;

  const reply = (ok, error) => postNative({ type: "result", id: message.id, ok, ...(error ? { error } : {}) });
  const entry = tabs.get(message.tabId);
  if (!entry) return reply(false, "tab-gone");
  if (message.command === "focus") {
    try {
      await focusTab(message.tabId);
      reply(true);
    } catch (error) {
      reply(false, String(error?.message ?? error));
    }
    return;
  }
  entry.port.postMessage(message); // the tab replies with a result of its own
}

function isMusicTab(sender) {
  return sender?.tab?.id !== undefined && typeof sender.url === "string" &&
    ORIGINS.some((origin) => sender.url.startsWith(origin + "/"));
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== PORT_NAME || !isMusicTab(port.sender)) {
    port.disconnect();
    return;
  }
  const tabId = port.sender.tab.id;
  tabs.set(tabId, { port, windowId: port.sender.tab.windowId, last: null });
  nativeRetries = 0;
  connectNative();

  port.onMessage.addListener((message) => {
    const entry = tabs.get(tabId);
    if (!entry || !message || typeof message.type !== "string") return;
    if (message.type === "session") {
      entry.last = message;
      postNative({ ...message, tabId, windowId: entry.windowId });
    } else if (message.type === "result") {
      postNative(message);
    }
  });

  port.onDisconnect.addListener(() => {
    if (tabs.get(tabId)?.port !== port) return;
    tabs.delete(tabId);
    postNative({ type: "removed", tabId });
    // Let Chrome stop the host (and this worker sleep) once no music tab is left.
    if (tabs.size === 0 && native) {
      native.disconnect();
      native = null;
    }
  });
});

// Tabs keep their id when moved between windows; keep the window id current for focusing.
chrome.tabs.onAttached.addListener((tabId, info) => {
  const entry = tabs.get(tabId);
  if (entry) entry.windowId = info.newWindowId;
});

// Content scripts are not injected into tabs that were already open when the
// extension was installed or reloaded, so inject them once here.
chrome.runtime.onInstalled.addListener(async () => {
  const open = await chrome.tabs.query({ url: ORIGINS.map((origin) => origin + "/*") });
  for (const tab of open) {
    // The bridge only catches handlers registered after it loads, so these tabs fall back to the
    // site's buttons until the page reloads.
    chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["media-session-bridge.js"], world: "MAIN" }).catch(() => {});
    chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["policy.js", "content.js"] }).catch(() => {});
  }
});
