// Orilio content script: one shared core, one small adapter per site. Runs in the extension's
// isolated world and never touches the page's JavaScript.
//
// State comes, in order of preference, from:
//   1. a <video>/<audio> element in the page (events, position, duration, seek),
//   2. navigator.mediaSession (metadata, artwork, playbackState),
//   3. the site's player bar (only where no API exists: buttons, and as a metadata fallback).
// If the playing state can't be read from any of them, nothing is reported rather than a guess.

(() => {
  if (window.__orilioContent) return; // already injected (install-time injection + manifest)
  window.__orilioContent = true;

  const PORT_NAME = "orilio-media";
  const HEARTBEAT_MS = 25_000; // keeps the session alive in Orilio; changes are reported on events
  const MAX_RECONNECTS = 8;

  const policy = globalThis.OrilioPolicy; // policy.js, loaded first
  const text = (root, selector) => root?.querySelector(selector)?.textContent?.trim() || null;
  const clock = policy.clock;
  const number = (value) => (Number.isFinite(Number.parseFloat(value)) ? Number.parseFloat(value) : null);

  const ADAPTERS = {
    "music.youtube.com": {
      site: "youtube-music",
      kind: "music",
      root: () => document.querySelector("ytmusic-player-bar"),
      title: (r) => text(r, ".title"),
      // The byline reads "Artist • Album • 2021".
      artist: (r) => (text(r, ".byline") ?? "").split("•")[0]?.trim() || null,
      album: (r) => (text(r, ".byline") ?? "").split("•")[1]?.trim() || null,
      artwork: (r) => r?.querySelector("img.image")?.src ?? null,
      playing: () => null, // the <video> element answers this
      position: () => null,
      duration: () => null,
      buttons: { playPause: "#play-pause-button", next: ".next-button", previous: ".previous-button" },
      watch: [".title", "img.image"],
    },
    "open.spotify.com": {
      site: "spotify",
      kind: "music",
      root: () => document.querySelector('[data-testid="now-playing-bar"]') ?? document.querySelector("footer"),
      title: (r) => text(r, '[data-testid="context-item-link"]'),
      artist: (r) => text(r, '[data-testid="context-item-info-artist"]'),
      album: () => null,
      artwork: (r) => r?.querySelector('[data-testid="cover-art-image"]')?.src ?? null,
      playing: () => null, // labels are localized, so the button text is not trusted for state
      position: (r) => clock(text(r, '[data-testid="playback-position"]')),
      duration: (r) => clock(text(r, '[data-testid="playback-duration"]')),
      buttons: {
        playPause: '[data-testid="control-button-playpause"]',
        next: '[data-testid="control-button-skip-forward"]',
        previous: '[data-testid="control-button-skip-back"]',
      },
      watch: ['[data-testid="context-item-link"]', '[data-testid="control-button-playpause"]', '[data-testid="cover-art-image"]'],
    },
    "soundcloud.com": {
      site: "soundcloud",
      kind: "music",
      root: () => document.querySelector(".playControls"),
      title: (r) => r?.querySelector(".playbackSoundBadge__titleLink")?.getAttribute("title") || null,
      artist: (r) => text(r, ".playbackSoundBadge__lightLink"),
      album: () => null,
      artwork: (r) => {
        const style = r?.querySelector(".playbackSoundBadge__avatar .image span")?.style?.backgroundImage ?? "";
        const url = style.match(/url\("?(.*?)"?\)/)?.[1] ?? null;
        return url ? url.replace(/-t\d+x\d+\./, "-t500x500.") : null; // ask for the large size
      },
      playing: (r) => {
        const button = r?.querySelector(".playControls__play");
        return button ? button.classList.contains("playing") : null; // class names are not localized
      },
      position: (r) => number(r?.querySelector(".playbackTimeline__progressWrapper")?.getAttribute("aria-valuenow")),
      duration: (r) => number(r?.querySelector(".playbackTimeline__progressWrapper")?.getAttribute("aria-valuemax")),
      buttons: { playPause: ".playControls__play", next: ".skipControl__next", previous: ".skipControl__previous" },
      watch: [".playbackSoundBadge__titleLink", ".playControls__play"],
    },
    "www.youtube.com": {
      site: "youtube",
      kind: "video",
      root: () => document.querySelector("#movie_player"),
      title: () => text(document, "ytd-watch-metadata h1"),
      artist: () => text(document, "ytd-watch-metadata ytd-channel-name a"),
      album: () => null,
      artwork: () => {
        const id = new URLSearchParams(location.search).get("v");
        return id && /^[\w-]{6,20}$/.test(id) ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : null;
      },
      playing: () => null, // the <video> element answers this
      position: () => null,
      duration: () => null,
      buttons: { playPause: ".ytp-play-button", next: ".ytp-next-button", previous: ".ytp-prev-button" },
      watch: [], // YouTube's own navigation event and media events cover every change
      events: ["yt-navigate-finish"],
    },
  };
  ADAPTERS["youtube.com"] = ADAPTERS["www.youtube.com"];

  const adapter = ADAPTERS[location.hostname];
  if (!adapter) return;

  let port = null;
  let reconnects = 0;
  let reconnectTimer = null;
  let heartbeat = null;
  let changeTimer = null;

  /** The site's player element, if it is part of the page (some sites play detached audio). */
  function media() {
    return policy.pickMedia([...document.querySelectorAll("video, audio")], {
      acceptsMuted: policy.acceptsMutedMedia(adapter.site, location.pathname),
      hasMetadata: Boolean(navigator.mediaSession?.metadata),
    });
  }

  function button(name) {
    const selector = adapter.buttons[name];
    return selector ? adapter.root()?.querySelector(selector) ?? null : null;
  }

  function largestArtwork(metadata, root) {
    const art = [...(metadata?.artwork ?? [])];
    const size = (a) => Number.parseInt(String(a.sizes ?? "").split("x")[0], 10) || 0;
    art.sort((a, b) => size(b) - size(a));
    const src = art[0]?.src ?? adapter.artwork(root);
    return src && src.startsWith("https://") ? src : null;
  }

  function playingState(element) {
    if (element) return !(element.paused || element.ended);
    const session = navigator.mediaSession?.playbackState;
    if (session === "playing" || session === "paused") return session === "playing";
    return adapter.playing(adapter.root());
  }

  function snapshot() {
    if (policy.isIgnoredPage(adapter.site, location.pathname)) return { type: "session", site: adapter.site, state: "stopped" };
    const root = adapter.root();
    const element = media();
    const metadata = navigator.mediaSession?.metadata ?? null;
    const title = metadata?.title || adapter.title(root);
    const playing = playingState(element);
    if (!title || playing === null) return { type: "session", site: adapter.site, state: "stopped" };

    const elementDuration = element && Number.isFinite(element.duration) && element.duration > 0 ? element.duration : null;
    const duration = elementDuration ?? adapter.duration(root);
    const position = element && Number.isFinite(element.currentTime) ? element.currentTime : adapter.position(root);

    const capabilities = ["focus"];
    if (element || button("playPause")) capabilities.push("playPause");
    if (element && elementDuration) capabilities.push("seek"); // never fake a seek with clicks on a bar
    if (button("next")) capabilities.push("next");
    if (button("previous")) capabilities.push("previous");

    return {
      type: "session",
      site: adapter.site,
      state: playing ? "playing" : "paused",
      title,
      artist: metadata?.artist || adapter.artist(root),
      album: metadata?.album || adapter.album(root),
      artwork: largestArtwork(metadata, root),
      duration,
      position,
      capabilities,
      pwa: window.matchMedia("(display-mode: standalone)").matches,
      buffering: Boolean(element && !element.paused && element.readyState < HTMLMediaElement.HAVE_FUTURE_DATA),
      kind: adapter.kind,
      visible: document.visibilityState === "visible",
    };
  }

  function report() {
    if (!port) {
      // Something happened while disconnected: try again now instead of waiting for a timer
      // (and even after the retry budget ran out).
      if (!reconnectTimer) connect();
      return;
    }
    try {
      port.postMessage(snapshot());
    } catch {
      // Port died between checks; onDisconnect handles reconnection.
    }
  }

  function perform(message) {
    const done = (ok, error) => port?.postMessage({ type: "result", id: message.id, ok, ...(error ? { error } : {}) });
    const element = media();
    const wantPlaying = { play: true, pause: false, toggle: !playingState(element) }[message.command];

    if (wantPlaying !== undefined) {
      if (element) {
        if (wantPlaying) element.play().then(() => done(true), (e) => done(false, String(e)));
        else { element.pause(); done(true); }
        return;
      }
      const control = button("playPause");
      if (!control) return done(false, "unsupported");
      if (playingState(null) !== wantPlaying) control.click(); // the site's button is a toggle
      return done(true);
    }
    if (message.command === "next" || message.command === "previous") {
      const control = button(message.command);
      if (!control) return done(false, "unsupported");
      control.click();
      return done(true);
    }
    if (message.command === "seek") {
      if (!element || !Number.isFinite(message.position) || message.position < 0) return done(false, "unsupported");
      element.currentTime = Math.min(message.position, Number.isFinite(element.duration) ? element.duration : message.position);
      return done(true);
    }
    done(false, "unsupported");
  }

  function connect() {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    if (port || !chrome.runtime?.id) return; // connected already, or orphaned by an extension reload
    try {
      port = chrome.runtime.connect({ name: PORT_NAME });
    } catch {
      port = null;
      return scheduleReconnect();
    }
    reconnects = 0;
    port.onMessage.addListener((message) => {
      if (message?.type === "resync") report();
      else if (message?.type === "command" && typeof message.id === "string") perform(message);
    });
    port.onDisconnect.addListener(() => {
      port = null;
      clearInterval(heartbeat);
      scheduleReconnect();
    });
    clearInterval(heartbeat);
    heartbeat = setInterval(report, HEARTBEAT_MS);
    report();
  }

  // The service worker can be stopped by Chrome; reconnecting wakes it again.
  function scheduleReconnect() {
    if (reconnects >= MAX_RECONNECTS || reconnectTimer) return;
    reconnectTimer = setTimeout(connect, Math.min(30_000, 500 * 2 ** reconnects++));
  }

  function reportSoon() {
    clearTimeout(changeTimer);
    changeTimer = setTimeout(report, 150);
  }

  // Media events don't bubble, but they can be captured at the document,
  // which also covers the element being replaced.
  for (const type of ["play", "playing", "pause", "ended", "seeked", "durationchange", "loadedmetadata", "emptied",
                      "ratechange", "waiting", "canplay", "stalled", "volumechange"]) {
    document.addEventListener(type, report, true);
  }
  // Tab shown or hidden: a background video must not take the island from music.
  document.addEventListener("visibilitychange", report);
  for (const type of adapter.events ?? []) document.addEventListener(type, reportSoon);

  // Changes without a media event (track swaps, detached audio): watch only the few nodes that
  // carry title and play state. Time and progress nodes change every second and are left alone.
  const observer = new MutationObserver(reportSoon);
  let watchAttempts = 0;
  const watch = () => {
    if (adapter.watch.length === 0) return report();
    const root = adapter.root();
    const nodes = root ? adapter.watch.map((s) => root.querySelector(s)).filter(Boolean) : [];
    if (nodes.length === 0) {
      // The player bar appears only once something plays; look again, less and less often.
      return setTimeout(watch, Math.min(10_000, 1_000 * ++watchAttempts));
    }
    for (const node of nodes) {
      observer.observe(node, {
        subtree: true, characterData: true, childList: true,
        attributes: true, attributeFilter: ["class", "src", "title", "style", "aria-label"],
      });
    }
    report();
  };
  watch();
  connect();
})();
