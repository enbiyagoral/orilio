// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func table(_ language: String) throws -> [String: String] {
    let url = repo.appending(path: "Resources/Localization/\(language).lproj/Localizable.strings")
    return try #require(NSDictionary(contentsOf: url) as? [String: String])
}

/// %@ and %lld, positional or not ("%1$@" counts as "@").
private func specifiers(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(?:\d\$)?(@|lld)"#)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range(at: 1)) }.sorted()
}

struct LocalizationTests {
    @Test func theTurkishTableIsWellFormed() throws {
        let tr = try table("tr")
        #expect(tr.count > 700)
        for (key, value) in tr {
            #expect(!value.isEmpty, "empty translation for \(key)")
            // A translation keeps every argument, except a sentence that words "the notch" itself (a lone %@).
            let k = specifiers(key), v = specifiers(value)
            #expect(k == v || (k == ["@"] && v.isEmpty), "\(key) → \(value)")
        }
    }

    /// Every fixed string the interface shows has a Turkish entry, so a new one can't slip in untranslated.
    @Test func everyFixedStringHasATurkishEntry() throws {
        let tr = try table("tr")
        let pattern = try NSRegularExpression(pattern: #"(?:\bText|\bL|\bButton|\.help|title:|detail:|label:|note:)\(?\s*"((?:[^"\\]|\\[^(])+)""#)
        let ignored: Set<String> = ["⌘", "+", "−", "⏎", "·", "Orilio", "GitHub", "Spotify", "Music"]
        let sources = FileManager.default.enumerator(at: repo.appending(path: "Sources/OrilioPrototype"), includingPropertiesForKeys: nil)!
        var missing: [String] = []
        for case let file as URL in sources where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = (text as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
                guard literal.rangeOfCharacter(from: .letters) != nil, !ignored.contains(literal),
                      literal.range(of: #"^[a-z0-9.]+$"#, options: .regularExpression) == nil, tr[literal] == nil else { continue }
                missing.append("\(file.lastPathComponent): \(literal)")
            }
        }
        #expect(missing.isEmpty, "\(missing.sorted().joined(separator: "\n"))")
    }
}
