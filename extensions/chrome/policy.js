// Pure decisions shared by the content script and the service worker. No DOM or Chrome APIs,
// so they can be tested with Node (Tests/Extension).

// Assigned to globalThis (not `const`) so content.js and the service worker can see it, and so a
// second injection into the same tab doesn't throw.
globalThis.OrilioPolicy ??= {
  /**
   * The media element that counts as playback the user chose, or null.
   * Muted elements are autoplay previews unless the page is a real player page
   * (`acceptsMuted`) and the site announces the media through Media Session.
   */
  pickMedia(elements, { acceptsMuted, hasMetadata }) {
    const loaded = elements.filter((m) => m.currentSrc || m.src);
    return loaded.find((m) => !m.muted) ?? (acceptsMuted && hasMetadata ? loaded[0] ?? null : null);
  },

  /** Pages whose media is never reported, by site. */
  isIgnoredPage(site, pathname) {
    return site === "youtube" && pathname.startsWith("/shorts");
  },

  /** Muted media on a real player page may still be what the user is watching. */
  acceptsMutedMedia(site, pathname) {
    return site !== "youtube" || /^\/(watch|live)/.test(pathname);
  },

  /** A short display name from navigator.userAgentData.brands. */
  browserName(brands) {
    const names = { "Google Chrome": "Chrome", "Microsoft Edge": "Edge" };
    const brand = (brands ?? []).map((b) => b.brand).find((b) => !/Not.?A.?Brand|^Chromium$/i.test(b));
    return names[brand] ?? brand ?? "Chromium";
  },

  /** "1:02:03" or "3:45" in seconds, or null. */
  clock(value) {
    const parts = String(value ?? "").trim().split(":").map(Number);
    if (parts.length < 2 || parts.some((n) => !Number.isFinite(n))) return null;
    return parts.reduce((total, n) => total * 60 + n, 0);
  },
};

if (typeof module === "object") module.exports = globalThis.OrilioPolicy;
