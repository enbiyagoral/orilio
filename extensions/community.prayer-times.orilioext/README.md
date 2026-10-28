# Prayer Times

The next prayer and a countdown in the notch, today's five times when the island opens, and a
reminder before each one. The times are Diyanet İşleri Başkanlığı's own, from the
[EzanVakti API](https://ezanvakti.emushaf.net) — the only place this extension connects to. A month is
kept on your Mac, so it keeps working offline.

It is also Orilio's reference extension. An extension is two files — a manifest and a script — and
never draws anything: it returns data, and Orilio shows it with its own components.

## The manifest, line by line

`orilio-extension.json` declares everything up front. Orilio refuses a manifest with keys it
doesn't know, and an extension can never do more than its manifest says.

```json
"schema": 1,
```
The manifest format. Always 1 for now.

```json
"id": "community.prayer-times",
```
Unique and permanent: lowercase, dot-separated. Settings, storage and reminders are kept under it.

```json
"name": "Prayer Times",
"version": "0.3.0",
"author": "Orilio contributors",
"license": "GPL-3.0-or-later",
```
Shown in the catalog and in Settings. `version` is `major.minor.patch`; a higher one in the catalog
offers an update.

```json
"minOrilio": "0.1.0",
```
The oldest Orilio this works with.

```json
"provides": ["widget.ear", "widget.island", "reminders"],
```
What the extension may fill: the collapsed island's ears, the Extensions tab, and scheduled
notifications. `actions` (buttons that call `onAction`) is the fourth.

```json
"refresh": { "everyMinutes": 60 },
```
How often Orilio calls `refresh`. Never more often than every 5 minutes; the result's `refreshAt`
asks for one more at the moment it goes stale (here, when the next prayer begins).

```json
"permissions": {
  "network": ["ezanvakti.emushaf.net"],
  "notifications": true,
  "location": "city-picker",
  "storage": true
},
```
Every capability, shown to the user before install:

- `network` — the exact HTTPS hosts `orilio.fetch` may reach. Here only `ezanvakti.emushaf.net`;
  empty means no internet at all. Redirects to other hosts are refused.
- `notifications` — reminders scheduled as macOS notifications, under Orilio's name.
- `location` — only `"city-picker"`: a city the user picks by name, with its coordinates and time
  zone. Never GPS.
- `storage` — a small key–value store (64 KB) kept for the extension on this Mac (`orilio.storage`).
  Here: the district found for your city and its month of times.

An extension can never reach the camera, the clipboard, Shelf files, screenshots, other windows or
other extensions' data. An update that asks for more permissions asks the user again.

```json
"settings": [
  { "key": "city", "type": "city", "label": "City" },
  { "key": "remindBefore", "type": "choice", "label": "Remind me before", "default": 10, "options": [ … ] },
  { "key": "notifyAtTime", "type": "toggle", "label": "Notify at prayer time", "default": true },
  { "key": "showCountdown", "type": "toggle", "label": "Show countdown in the notch", "default": true }
]
```
The settings form Orilio draws: `city` (needs `"location": "city-picker"`), `select` (a menu, not used here),
`choice` (a segmented control) and `toggle`. The values arrive in `ctx.settings`; a change calls
`onSettingsChanged`.

## The script

`main.js` defines `refresh(ctx)` (and optionally `onSettingsChanged(ctx)` and `onAction(ctx)`).
`ctx` has `settings`, `storage`, `now`, `locale` and `timeZone`. It returns:

```js
{
  ear: { leading: { text: "İkindi" }, trailing: { style: "countdown", target: "2026-10-28T12:45:00Z" } },
  island: { sections: [
    { type: "hero", label: "Sıradaki vakit", title: "İkindi", countdownTo: "…", caption: "15:45’de" },
    { type: "list", rows: [{ title: "Sabah", value: "05:57", state: "past" }, …] },
    { type: "footnote", text: "…" },
  ] },
  reminders: [{ id: "asr-before-…", date: "…", title: "İkindi 10 dakika sonra", body: "15:45" }],
  refreshAt: "…",
}
```

Countdowns are drawn by Orilio from the `target` date, so the script isn't called every minute.
A section `{ type: "notice", title, detail }` shows an empty or error state ("Choose a city").
Each call has 5 seconds; every extension runs in its own JavaScript machine inside one sandboxed
process with no network of its own.

## Where the times come from

1. The city you pick (its province and district, from macOS) is matched to Diyanet's district list:
   `/sehirler/2` (Türkiye's provinces), then `/ilceler/<province>`; the province centre when your
   district isn't listed.
2. `/vakitler/<district>` gives about a month of Diyanet's published times. They are kept in storage
   and fetched again when the month runs out.
3. With no connection and nothing kept (or a city outside Türkiye), the times are calculated here from
   the sun's position with Diyanet's degrees and caution minutes (imsak −18°, yatsı −17°, güneş −7 min,
   öğle +5, ikindi +4, akşam +7). They are usually within a minute or two of the official ones, and the
   island says they're calculated.

EzanVakti isn't run by Diyanet; it serves Diyanet's published times. The island names it under the list.

## License

GPL-3.0-or-later. See `LICENSE`.
