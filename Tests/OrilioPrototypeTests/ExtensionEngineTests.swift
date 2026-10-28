// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioExtensionEngine
@testable import OrilioExtensionKit

/// The Prayer Times package in the repository (the reference extension).
private let prayerFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "extensions/community.prayer-times.orilioext")

private func run(_ engine: ExtensionEngine, _ queue: DispatchQueue, id: String, _ context: CallContext, function: String = "refresh") async -> Result<CallReply, EngineError> {
    await withCheckedContinuation { continuation in
        queue.async { engine.call(id: id, function: function, context: context) { continuation.resume(returning: $0) } }
    }
}

private func istanbul(_ iso: String, method: String = "diyanet", locale: String = "tr-TR") -> CallContext {
    CallContext(settings: ["city": .object(["name": .string("İstanbul"), "latitude": .number(41.0082), "longitude": .number(28.9784),
                                             "timeZone": .string("Europe/Istanbul")]),
                           "method": .string(method), "remindBefore": .number(10), "notifyAtTime": .bool(true), "showCountdown": .bool(true)],
                storage: [:], now: ISO8601DateFormatter().date(from: iso)!, locale: locale, timeZone: "Europe/Istanbul")
}

struct PrayerTimesExtensionTests {
    let queue = DispatchQueue(label: "test.engine")

    /// Offline by default; `responses` answers EzanVakti paths ("/sehirler/2" …) like the API does.
    private func engine(_ responses: [String: String] = [:]) throws -> ExtensionEngine {
        let engine = ExtensionEngine(queue: queue) { _, url, _, _, completion in
            guard let body = responses.first(where: { url.hasSuffix($0.key) })?.value else { return completion(nil, 0, "offline") }
            completion(Data(body.utf8), 200, nil)
        }
        let manifest = try ManifestValidator.validate(Data(contentsOf: prayerFolder.appending(path: "orilio-extension.json")))
        let script = try String(contentsOf: prayerFolder.appending(path: "main.js"), encoding: .utf8)
        try queue.sync { try engine.load(id: manifest.id, script: script, manifest: manifest) }
        return engine
    }

    @Test func theManifestIsValid() throws {
        let manifest = try ManifestValidator.validate(Data(contentsOf: prayerFolder.appending(path: "orilio-extension.json")))
        #expect(manifest.permissions.network == ["ezanvakti.emushaf.net"]) // Diyanet's times, and nothing else
        #expect(manifest.permissions.location == "city-picker")
    }

    @Test func todaysTimesInOrderWithTheNextOneHighlighted() async throws {
        let engine = try engine()
        let reply = try await run(engine, queue, id: "community.prayer-times", istanbul("2026-10-28T13:30:00Z")).get() // 16:30 in İstanbul
        let result = try ExtensionResult.decode(reply.result)
        guard case .list(let rows)? = result.island?.sections.first(where: { if case .list = $0 { true } else { false } }) else {
            Issue.record("no list"); return
        }
        #expect(rows.map(\.title) == ["Sabah", "Öğle", "İkindi", "Akşam", "Yatsı"])
        #expect(rows.map(\.value) == rows.map(\.value).sorted()) // in order through the day
        #expect(rows.filter { $0.state == .next }.count == 1)
        #expect(result.ear?.trailing?.style == "countdown")
        #expect(!(result.reminders ?? []).isEmpty)
        #expect(result.refreshAt != nil)
    }

    /// Diyanet's İstanbul times for 28 October 2026, as the EzanVakti API serves them.
    @Test func diyanetsPublishedTimesFromTheAPI() async throws {
        let day = { (date: String, times: [String]) in
            #"{"MiladiTarihKisa":"\#(date)","Imsak":"\#(times[0])","Gunes":"\#(times[1])","Ogle":"\#(times[2])","Ikindi":"\#(times[3])","Aksam":"\#(times[4])","Yatsi":"\#(times[5])"}"#
        }
        let engine = try engine([
            "/sehirler/2": #"[{"SehirAdi":"ANKARA","SehirID":"506"},{"SehirAdi":"İSTANBUL","SehirID":"539"}]"#,
            "/ilceler/539": #"[{"IlceAdi":"ARNAVUTKOY","IlceID":"9535"},{"IlceAdi":"İSTANBUL","IlceID":"9541"}]"#,
            "/vakitler/9541": "[" + day("28.10.2026", ["05:57", "07:23", "12:53", "15:45", "18:13", "19:33"]) + ","
                + day("29.10.2026", ["05:58", "07:24", "12:53", "15:44", "18:12", "19:32"]) + "]",
        ])
        let reply = try await run(engine, queue, id: "community.prayer-times", istanbul("2026-10-28T01:00:00Z")).get()
        let result = try ExtensionResult.decode(reply.result)
        guard case .list(let rows)? = result.island?.sections.first(where: { if case .list = $0 { true } else { false } }) else {
            Issue.record("no list"); return
        }
        #expect(rows.map(\.value) == ["05:57", "12:53", "15:45", "18:13", "19:33"])
        #expect(reply.storage["diyanet"] != nil) // kept for offline use
        guard case .footnote(let source)? = result.island?.sections.last else { Issue.record("no footnote"); return }
        #expect(source.contains("EzanVakti"))
    }

    @Test func offlineItCalculatesAndSaysSo() async throws {
        let result = try ExtensionResult.decode(try await run(try engine(), queue, id: "community.prayer-times", istanbul("2026-10-28T01:00:00Z")).get().result)
        guard case .footnote(let source)? = result.island?.sections.last else { Issue.record("no footnote"); return }
        #expect(source.contains("çevrimdışı"))
    }

    @Test func withoutACityItAsksForOne() async throws {
        let engine = try engine()
        var context = istanbul("2026-10-28T10:00:00Z")
        context.settings["city"] = nil
        let result = try ExtensionResult.decode(try await run(engine, queue, id: "community.prayer-times", context).get().result)
        guard case .notice(let notice)? = result.island?.sections.first else { Issue.record("no notice"); return }
        #expect(notice.title == "Şehir seçin")
        #expect(result.ear == nil && result.reminders == nil)
    }
}
