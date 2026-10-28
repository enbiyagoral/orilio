// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

// Runs in the page's own JavaScript world, before the site's code (manifest: world MAIN, document_start).
// Its only job: remember the Media Session action handlers the site registers, and invoke one when
// Orilio's content script asks. This is the same path the keyboard's media keys take, aimed at this
// tab only, so next/previous/seek follow the site's own logic instead of guessing at buttons.
//
// The bridge touches nothing else: no network, no storage, no access to page data.

(() => {
  const session = navigator.mediaSession;
  if (!session || session.__orilioBridge) return;
  Object.defineProperty(session, "__orilioBridge", { value: true });

  const SUPPORTED = new Set(["nexttrack", "previoustrack", "seekto"]);
  const handlers = new Map();
  const register = session.setActionHandler.bind(session);

  // Published as a DOM attribute so the extension's isolated world can read it.
  // Written only when it changes: some sites re-register handlers very often.
  const publish = () => {
    const value = [...handlers.keys()].sort().join(" ");
    const root = document.documentElement;
    if (root && root.dataset.orilioActions !== value) root.dataset.orilioActions = value;
  };

  session.setActionHandler = (action, handler) => {
    if (SUPPORTED.has(action)) {
      if (handler) handlers.set(action, handler);
      else handlers.delete(action);
      publish();
    }
    return register(action, handler);
  };

  // Requests arrive as strings: "nexttrack", "previoustrack" or "seekto:<seconds>".
  document.addEventListener("orilio:media-action", (event) => {
    if (typeof event.detail !== "string") return;
    const [action, value] = event.detail.split(":");
    const handler = handlers.get(action);
    if (!handler) return;
    const seekTime = Number(value);
    if (action === "seekto") {
      if (Number.isFinite(seekTime) && seekTime >= 0) handler({ action, seekTime });
    } else {
      handler({ action });
    }
  });
})();
