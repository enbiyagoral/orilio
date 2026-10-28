// Run with: node --test Tests/Extension/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const policy = createRequire(import.meta.url)("../../extensions/chrome/policy.js");
const media = (props) => ({ currentSrc: "blob:x", muted: false, ...props });

test("muted autoplay previews are not playback", () => {
  const preview = media({ muted: true });
  assert.equal(policy.pickMedia([preview], { acceptsMuted: false, hasMetadata: true }), null);
  assert.equal(policy.pickMedia([preview], { acceptsMuted: true, hasMetadata: false }), null);
  assert.equal(policy.pickMedia([preview], { acceptsMuted: true, hasMetadata: true }), preview);
});

test("an audible element wins over a muted one", () => {
  const preview = media({ muted: true }), player = media();
  assert.equal(policy.pickMedia([preview, player], { acceptsMuted: false, hasMetadata: false }), player);
});

test("unloaded elements are ignored", () => {
  assert.equal(policy.pickMedia([{ currentSrc: "", src: "", muted: false }], { acceptsMuted: true, hasMetadata: true }), null);
});

test("YouTube Shorts are ignored, watch pages are not", () => {
  assert.equal(policy.isIgnoredPage("youtube", "/shorts/abc"), true);
  assert.equal(policy.isIgnoredPage("youtube", "/watch"), false);
  assert.equal(policy.isIgnoredPage("youtube-music", "/shorts"), false);
});

test("muted media counts only on YouTube player pages", () => {
  assert.equal(policy.acceptsMutedMedia("youtube", "/watch"), true);
  assert.equal(policy.acceptsMutedMedia("youtube", "/live/x"), true);
  assert.equal(policy.acceptsMutedMedia("youtube", "/"), false);
  assert.equal(policy.acceptsMutedMedia("youtube", "/results"), false);
  assert.equal(policy.acceptsMutedMedia("spotify", "/"), true);
});

test("browser names", () => {
  const brands = (...names) => names.map((brand) => ({ brand, version: "1" }));
  assert.equal(policy.browserName(brands("Not)A;Brand", "Chromium", "Google Chrome")), "Chrome");
  assert.equal(policy.browserName(brands("Chromium", "Brave", "Not_A Brand")), "Brave");
  assert.equal(policy.browserName(brands("Microsoft Edge", "Chromium")), "Edge");
  assert.equal(policy.browserName(brands("Chromium")), "Chromium");
  assert.equal(policy.browserName(undefined), "Chromium");
});

test("clock parsing", () => {
  assert.equal(policy.clock("3:45"), 225);
  assert.equal(policy.clock("1:02:03"), 3723);
  assert.equal(policy.clock("live"), null);
  assert.equal(policy.clock(null), null);
});
