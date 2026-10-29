// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

struct Note: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    /// The first non-empty line, for the notes list.
    var title: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Empty note"
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct TaskItem: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var title: String
    var done: Bool
    let createdAt: Date
    var completedAt: Date?
    /// A day, stored as its start in the user's time zone at the time it was set.
    var due: Date?
}

/// What is on disk. Fields added later must be optional (or have defaults when decoding), so an
/// older file still decodes; `version` changes only when old data has to be rewritten.
struct NotesFile: Codable, Equatable {
    static let currentVersion = 1
    var version = NotesFile.currentVersion
    var notes: [Note] = []
    var tasks: [TaskItem] = []
}

enum NotesPolicy {
    /// Tasks still to do, in the user's order, then the done ones, most recently finished first.
    static func ordered(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { !$0.done } + tasks.filter(\.done).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Pinned first, then most recently edited.
    static func ordered(_ notes: [Note]) -> [Note] {
        notes.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    static func search(_ notes: [Note], _ query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? notes : notes.filter { $0.text.localizedStandardContains(q) }
    }

    /// "Today", "Tomorrow", "Yesterday" or a short date; nil when there's no due date.
    static func dueText(_ due: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let due else { return nil }
        if calendar.isDate(due, inSameDayAs: now) { return L("Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) { return L("Tomorrow") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(due, inSameDayAs: yesterday) { return L("Yesterday") }
        return due.formatted(.dateTime.day().month(.abbreviated))
    }

    static func isOverdue(_ task: TaskItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard !task.done, let due = task.due else { return false }
        return due < calendar.startOfDay(for: now)
    }

    /// A readable Markdown export: tasks as a checklist, then every note under its date.
    static func markdown(notes: [Note], tasks: [TaskItem]) -> String {
        var out = "# Orilio notes and tasks\n\n## Tasks\n\n"
        if tasks.isEmpty { out += "_No tasks._\n" }
        for task in ordered(tasks) {
            let due = task.due.map { " (due \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
            out += "- [\(task.done ? "x" : " ")] \(task.title)\(due)\n"
        }
        out += "\n## Notes\n"
        if notes.isEmpty { out += "\n_No notes._\n" }
        for note in ordered(notes) {
            out += "\n### \(note.title)\n\n"
            out += "_\(note.updatedAt.formatted(date: .abbreviated, time: .shortened))\(note.pinned ? " · pinned" : "")_\n\n"
            out += note.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        return out
    }
}

/// Where tasks could also be kept in a later version (Reminders). M3 keeps tasks local only.
// ponytail: no implementation on purpose; NotesModule calls it when set, so a Reminders adapter plugs in here.
protocol TaskSyncAdapter: Sendable {
    func upsert(_ task: TaskItem) async throws
    func delete(_ id: UUID) async throws
}

/// Notes and tasks on disk: `Application Support/Orilio/Notes/notes.json`, written atomically.
actor NotesStore {
    enum LoadResult: Equatable {
        case loaded(NotesFile)
        /// The file couldn't be read; it was kept next to the new one under this name.
        case recovered(NotesFile, backup: String)
    }

    let directory: URL
    private var file: URL { directory.appending(path: "notes.json") }

    init(directory: URL = NotesStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Orilio/Notes", directoryHint: .isDirectory)
    }

    /// A missing file is an empty start. A corrupt file, or one from a newer Orilio, is never
    /// overwritten: it is renamed aside and loading starts empty.
    func load() -> LoadResult {
        guard let data = try? Data(contentsOf: file) else { return .loaded(NotesFile()) }
        if let decoded = try? JSONDecoder.notes.decode(NotesFile.self, from: data), decoded.version <= NotesFile.currentVersion {
            return .loaded(migrate(decoded))
        }
        let backup = "notes-unreadable-\(Int(Date().timeIntervalSince1970)).json"
        try? FileManager.default.moveItem(at: file, to: directory.appending(path: backup))
        return .recovered(NotesFile(), backup: backup)
    }

    /// Version 1 is the first; later versions rewrite older data here.
    private func migrate(_ file: NotesFile) -> NotesFile {
        var file = file
        file.version = NotesFile.currentVersion
        return file
    }

    func save(_ contents: NotesFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.notes.encode(contents).write(to: file, options: .atomic)
    }
}

extension JSONEncoder {
    static var notes: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var notes: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
