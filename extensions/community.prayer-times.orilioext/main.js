// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

// Prayer Times — Orilio's reference extension.
//
// An extension never draws anything. Orilio calls `refresh(ctx)` and the extension returns data:
// what the ear says, the island's sections, the reminders to schedule and when it goes stale.
// Orilio renders all of it with its own components and counts down from the dates it is given.
//
// The times are Diyanet İşleri Başkanlığı's own, from the EzanVakti API (ezanvakti.emushaf.net), which
// serves Diyanet's published times per district. A month is kept in storage, so the island keeps working
// offline. Without it (no connection yet, or a city outside Türkiye) the times are calculated here from
// the sun's position with Diyanet's degrees and caution minutes, and the island says so.

/** Diyanet since 1983: imsak at -18°, yatsı at -17°, no caution on either; güneş 7 min earlier, öğle +5,
 *  ikindi +4, akşam +7 (vakithesaplama.diyanet.gov.tr/temkin.php). Only for the offline fallback. */
const DIYANET = { fajrAngle: 18, ishaAngle: 17, temkin: { fajr: 0, sunrise: -7, dhuhr: 5, asr: 4, maghrib: 7, isha: 0 } };

const NAMES = {
  tr: { fajr: "Sabah", dhuhr: "Öğle", asr: "İkindi", maghrib: "Akşam", isha: "Yatsı" },
  en: { fajr: "Fajr", dhuhr: "Dhuhr", asr: "Asr", maghrib: "Maghrib", isha: "Isha" },
};

// ---------------------------------------------------------------------------------------------
// The sun

const rad = (d) => (d * Math.PI) / 180;
const deg = (r) => (r * 180) / Math.PI;
const fix = (a, b) => { const x = a - b * Math.floor(a / b); return x < 0 ? x + b : x; };
const dsin = (d) => Math.sin(rad(d));
const dcos = (d) => Math.cos(rad(d));
const dtan = (d) => Math.tan(rad(d));
const darcsin = (x) => deg(Math.asin(x));
const darccos = (x) => deg(Math.acos(x));
const darctan2 = (y, x) => deg(Math.atan2(y, x));
const darccot = (x) => deg(Math.atan(1 / x));

function julian(year, month, day) {
  if (month <= 2) { year -= 1; month += 12; }
  const a = Math.floor(year / 100);
  const b = 2 - a + Math.floor(a / 4);
  return Math.floor(365.25 * (year + 4716)) + Math.floor(30.6001 * (month + 1)) + day + b - 1524.5;
}

/** The sun's declination and the equation of time (hours) for a Julian day: NOAA's solar equations. */
function sun(jd) {
  const t = (jd - 2451545.0) / 36525; // Julian centuries since J2000
  const l0 = fix(280.46646 + t * (36000.76983 + t * 0.0003032), 360);
  const m = 357.52911 + t * (35999.05029 - 0.0001537 * t);
  const e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
  const c = dsin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) + dsin(2 * m) * (0.019993 - 0.000101 * t) + dsin(3 * m) * 0.000289;
  const omega = 125.04 - 1934.136 * t;
  const lambda = l0 + c - 0.00569 - 0.00478 * dsin(omega);
  const obliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60 + 0.00256 * dcos(omega);
  const y = Math.pow(dtan(obliquity / 2), 2);
  const minutes = 4 * deg(y * dsin(2 * l0) - 2 * e * dsin(m) + 4 * e * y * dsin(m) * dcos(2 * l0)
    - 0.5 * y * y * dsin(4 * l0) - 1.25 * e * e * dsin(2 * m));
  return { declination: darcsin(dsin(obliquity) * dsin(lambda)), equation: minutes / 60 };
}

/** Hours (local solar day) for the five times and sunrise, before any caution minutes. */
function solarTimes(jd, lat, method) {
  const noon = (t) => fix(12 - sun(jd + t).equation, 24);
  const angleTime = (angle, t, before) => {
    const decl = sun(jd + t).declination;
    const span = darccos((-dsin(angle) - dsin(decl) * dsin(lat)) / (dcos(decl) * dcos(lat))) / 15;
    return noon(t) + (before ? -span : span);
  };
  const asr = (t) => {
    const decl = sun(jd + t).declination;
    return angleTime(-darccot(1 + dtan(Math.abs(lat - decl))), t, false); // shadow = 1 × height + noon shadow
  };
  // A first guess at each time, then once more from it, as the sun moves during the day.
  let t = { fajr: 5, sunrise: 6, dhuhr: 12, asr: 13, maghrib: 18, isha: 18 };
  for (let i = 0; i < 2; i++) {
    const p = Object.fromEntries(Object.entries(t).map(([k, v]) => [k, v / 24]));
    t = {
      fajr: angleTime(method.fajrAngle, p.fajr, true),
      sunrise: angleTime(0.833, p.sunrise, true),
      dhuhr: noon(p.dhuhr),
      asr: asr(p.asr),
      maghrib: angleTime(0.833, p.maghrib, false),
      isha: angleTime(method.ishaAngle, p.isha, false),
    };
  }
  return t;
}

// ---------------------------------------------------------------------------------------------
// Dates in the city's time zone

/** The city's UTC offset in minutes at `date` (Intl knows every zone's rules, daylight saving included). */
function offsetMinutes(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(date);
  const v = Object.fromEntries(parts.map((p) => [p.type, Number(p.value)]));
  return Math.round((Date.UTC(v.year, v.month - 1, v.day, v.hour, v.minute, v.second) - date.getTime()) / 60000);
}

/** The calendar date in the city at `date`. */
function cityDate(date, timeZone) {
  const local = new Date(date.getTime() + offsetMinutes(date, timeZone) * 60000);
  return { year: local.getUTCFullYear(), month: local.getUTCMonth() + 1, day: local.getUTCDate() };
}

/** One day's calculated times as instants, each rounded to the minute, caution minutes applied. */
function dayTimes(day, city, method) {
  const noonGuess = new Date(Date.UTC(day.year, day.month - 1, day.day, 12));
  const offset = offsetMinutes(noonGuess, city.timeZone);
  const jd = julian(day.year, day.month, day.day) - city.longitude / (15 * 24);
  const solar = solarTimes(jd, city.latitude, method);
  const midnightUTC = Date.UTC(day.year, day.month - 1, day.day) - offset * 60000;
  const out = {};
  for (const [key, hours] of Object.entries(solar)) {
    const localHours = hours + offset / 60 - city.longitude / 15;
    const minutes = Math.round(localHours * 60) + (method.temkin[key] || 0);
    out[key] = new Date(midnightUTC + minutes * 60000);
  }
  return out;
}

const pad = (n) => String(n).padStart(2, "0");
function clock(date, timeZone) {
  const local = new Date(date.getTime() + offsetMinutes(date, timeZone) * 60000);
  return pad(local.getUTCHours()) + ":" + pad(local.getUTCMinutes());
}

// ---------------------------------------------------------------------------------------------
// Diyanet's times from the EzanVakti API

const API = "https://ezanvakti.emushaf.net";

async function getJSON(path) {
  const response = await orilio.fetch(API + path);
  if (!response.ok) throw new Error("EzanVakti answered " + response.status);
  return JSON.parse(response.text);
}

/** "İstanbul", "ISTANBUL", "Arnavutköy" → comparable letters only. */
const plain = (s) => (s || "").toLocaleUpperCase("tr").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^A-Z]/g, "");

/** The district for a city (its own district, else the province centre), then that district's month. */
async function diyanetMonth(city, cached) {
  const key = city.latitude + "," + city.longitude;
  const place = cached && cached.key === key && cached.district ? cached : { key };
  if (!place.district) {
    if (city.countryCode && city.countryCode !== "TR") return null; // ponytail: Türkiye's districts only
    const cities = await getJSON("/sehirler/2"); // 2: Türkiye
    const province = plain(city.region || city.name.split(",")[0]);
    const match = cities.find((c) => plain(c.SehirAdi) === province);
    if (!match) return null;
    const districts = await getJSON("/ilceler/" + match.SehirID);
    const district = districts.find((d) => plain(d.IlceAdi) === plain(city.locality))
      || districts.find((d) => plain(d.IlceAdi) === plain(match.SehirAdi)) || districts[0];
    place.district = district.IlceID;
    place.districtName = district.IlceAdi;
  }
  const days = {};
  for (const v of await getJSON("/vakitler/" + place.district)) {
    days[v.MiladiTarihKisa.split(".").reverse().join("-")] = [v.Imsak, v.Gunes, v.Ogle, v.Ikindi, v.Aksam, v.Yatsi];
  }
  return { key, district: place.district, districtName: place.districtName, days };
}

const isoDay = (d) => d.year + "-" + pad(d.month) + "-" + pad(d.day);

/** A day's published times ("05:57" …) as instants in the city's time zone. */
function publishedTimes(day, clocks, timeZone) {
  const offset = offsetMinutes(new Date(Date.UTC(day.year, day.month - 1, day.day, 12)), timeZone);
  const midnightUTC = Date.UTC(day.year, day.month - 1, day.day) - offset * 60000;
  const at = (text) => { const [h, m] = text.split(":").map(Number); return new Date(midnightUTC + (h * 60 + m) * 60000); };
  const [fajr, sunrise, dhuhr, asr, maghrib, isha] = clocks.map(at);
  return { fajr, sunrise, dhuhr, asr, maghrib, isha };
}

// ---------------------------------------------------------------------------------------------
// What Orilio calls

const ORDER = ["fajr", "dhuhr", "asr", "maghrib", "isha"];

async function refresh(ctx) {
  const turkish = (ctx.locale || "").toLowerCase().startsWith("tr");
  const names = turkish ? NAMES.tr : NAMES.en;
  const city = ctx.settings.city;

  if (!city || typeof city.latitude !== "number" || typeof city.longitude !== "number" || !city.timeZone) {
    return {
      island: { sections: [{ type: "notice", icon: "location", title: turkish ? "Şehir seçin" : "Choose a city",
        detail: turkish ? "Vakitler, Prayer Times ayarlarında seçtiğiniz şehre göre hesaplanır." : "Times are calculated for the city you pick in the extension's settings." }] },
    };
  }

  const now = new Date(ctx.now);
  const today = cityDate(now, city.timeZone);
  const tomorrowDay = cityDate(new Date(now.getTime() + 24 * 3600 * 1000), city.timeZone);

  // Diyanet's own times: from storage, or fetched when the month runs out (or the city changed).
  let month = orilio.storage.get("diyanet");
  const key = city.latitude + "," + city.longitude;
  if (!month || month.key !== key || !month.days[isoDay(tomorrowDay)]) {
    try {
      const fresh = await diyanetMonth(city, month);
      if (fresh) { orilio.storage.set("diyanet", fresh); month = fresh; }
    } catch (error) {
      orilio.log("EzanVakti: " + error);
    }
  }
  const published = month && month.key === key && month.days[isoDay(today)] && month.days[isoDay(tomorrowDay)];
  const times = published ? publishedTimes(today, month.days[isoDay(today)], city.timeZone) : dayTimes(today, city, DIYANET);
  const tomorrow = published ? publishedTimes(tomorrowDay, month.days[isoDay(tomorrowDay)], city.timeZone) : dayTimes(tomorrowDay, city, DIYANET);

  // The next prayer: today's first one still ahead, else tomorrow's sabah.
  const nextKey = ORDER.find((k) => times[k] > now);
  const next = nextKey ? { key: nextKey, date: times[nextKey] } : { key: "fajr", date: tomorrow.fajr };

  const remindBefore = Number(ctx.settings.remindBefore ?? 10);
  const notifyAtTime = ctx.settings.notifyAtTime !== false;
  const showCountdown = ctx.settings.showCountdown !== false;

  const rows = ORDER.map((k) => ({
    title: names[k],
    value: clock(times[k], city.timeZone),
    state: !nextKey ? "past" : k === nextKey ? "next" : times[k] < now ? "past" : "later",
  }));
  if (!nextKey) rows[0] = { title: names.fajr, value: clock(tomorrow.fajr, city.timeZone), state: "next" };

  const at = clock(next.date, city.timeZone);
  const caption = turkish
    ? at + "’de" + (remindBefore > 0 ? " · " + remindBefore + " dk önce hatırlatılacak" : "")
    : "at " + at + (remindBefore > 0 ? " · reminder " + remindBefore + " min before" : "");

  // Every remaining time today and tomorrow's sabah: a reminder before it and one at it, as chosen.
  const upcoming = ORDER.filter((k) => times[k] > now).map((k) => ({ key: k, date: times[k] }));
  upcoming.push({ key: "fajr", date: tomorrow.fajr });
  const reminders = [];
  for (const p of upcoming) {
    const stamp = p.date.toISOString().slice(0, 16);
    if (remindBefore > 0) {
      reminders.push({
        id: p.key + "-before-" + stamp,
        date: new Date(p.date.getTime() - remindBefore * 60000).toISOString(),
        title: turkish ? names[p.key] + " " + remindBefore + " dakika sonra" : names[p.key] + " in " + remindBefore + " minutes",
        body: clock(p.date, city.timeZone),
      });
    }
    if (notifyAtTime) {
      reminders.push({
        id: p.key + "-at-" + stamp,
        date: p.date.toISOString(),
        title: turkish ? names[p.key] + " vakti" : "Time for " + names[p.key],
        body: clock(p.date, city.timeZone),
      });
    }
  }

  const source = published
    ? (turkish ? "Diyanet İşleri Başkanlığı vakitleri (" + month.districtName + ") · EzanVakti API"
               : "Diyanet's published times (" + month.districtName + ") · EzanVakti API")
    : (turkish ? "Diyanet yöntemiyle hesaplandı (çevrimdışı) · resmî vakitlerden 1–2 dk farklı olabilir"
               : "Calculated with Diyanet's method (offline) · may differ from official times by a minute or two");
  return {
    ear: showCountdown ? { leading: { text: names[next.key] }, trailing: { style: "countdown", target: next.date.toISOString(), tint: "mint" } } : undefined,
    island: {
      sections: [
        { type: "hero", label: turkish ? "Sıradaki vakit" : "Next prayer", title: names[next.key], countdownTo: next.date.toISOString(), caption },
        { type: "list", rows },
        { type: "footnote", text: source },
      ],
    },
    reminders,
    // When this goes stale: the next prayer begins, and the list's states change.
    refreshAt: new Date(next.date.getTime() + 1000).toISOString(),
  };
}

function onSettingsChanged(ctx) {
  return refresh(ctx);
}
