// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

@MainActor
private func makeModule(_ directory: URL = FileManager.default.temporaryDirectory.appending(path: "orilio-notes-\(UUID().uuidString)"),
                        now: @escaping @MainActor () -> Date = { Date(timeIntervalSinceReferenceDate: 800_000_000) }) async -> (NotesModule, URL) {
    let module = NotesModule(store: NotesStore(directory: directory), now: now)
    await module.load()
    return (module, directory)
}

struct NotesPolicyTests {
    @Test func openTasksFirstInTheirOrder() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func task(_ title: String, done: Bool = false, completed: Double = 0) -> TaskItem {
            TaskItem(id: UUID(), title: title, done: done, createdAt: t0, completedAt: done ? t0.addingTimeInterval(completed) : nil)
        }
        let tasks = [task("old done", done: true, completed: 1), task("a"), task("new done", done: true, completed: 9), task("b")]
        #expect(NotesPolicy.ordered(tasks).map(\.title) == ["a", "b", "new done", "old done"])
    }

    @Test func dueText() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let today = calendar.startOfDay(for: now)
        #expect(NotesPolicy.dueText(nil, now: now, calendar: calendar) == nil)
        #expect(NotesPolicy.dueText(today, now: now, calendar: calendar) == "Today")
        #expect(NotesPolicy.dueText(today.addingTimeInterval(86_400), now: now, calendar: calendar) == "Tomorrow")
        let overdue = TaskItem(id: UUID(), title: "x", done: false, createdAt: now, due: today.addingTimeInterval(-86_400))
        #expect(NotesPolicy.isOverdue(overdue, now: now, calendar: calendar))
    }

    @Test func markdownExportIsReadable() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let markdown = NotesPolicy.markdown(
            notes: [Note(id: UUID(), text: "Standup\n— cert renewal", createdAt: t, updatedAt: t, pinned: true)],
            tasks: [TaskItem(id: UUID(), title: "Ship beta", done: false, createdAt: t),
                    TaskItem(id: UUID(), title: "Reply", done: true, createdAt: t, completedAt: t)])
        #expect(markdown.contains("- [ ] Ship beta\n- [x] Reply\n"))
        #expect(markdown.contains("### Standup\n"))
        #expect(markdown.contains("— cert renewal\n"))
    }

    @Test func searchMatchesAnyPartOfTheText() {
        let t = Date.now
        let notes = [Note(id: UUID(), text: "Grafana access", createdAt: t, updatedAt: t, pinned: false),
                     Note(id: UUID(), text: "Erişim notları", createdAt: t, updatedAt: t, pinned: false)]
        #expect(NotesPolicy.search(notes, "grafana").count == 1)
        #expect(NotesPolicy.search(notes, "ERISIM").count == 1) // case and accents don't matter
        #expect(NotesPolicy.search(notes, " ").count == 2)
    }
}

@MainActor
struct NotesModuleTests {
    @Test func typingCreatesANoteAndEveryCharacterIsKept() async {
        let (module, _) = await makeModule()
        var text = ""
        for character in "Hızlı yazılan bir not — ŞĞÜÇÖİ 123" {
            text.append(character)
            module.currentText = text
        }
        #expect(module.notes.count == 1)
        #expect(module.currentText == "Hızlı yazılan bir not — ŞĞÜÇÖİ 123")
    }

    @Test func notesAndTasksSurviveARestart() async {
        let (module, directory) = await makeModule()
        module.currentText = "Remember this"
        module.addTask("Ship it")
        module.toggle(module.tasks[0])
        module.addTask("Then this")
        await module.saveNow()

        let (again, _) = await makeModule(directory)
        #expect(again.currentText == "Remember this")
        #expect(again.visibleTasks.map(\.title) == ["Then this", "Ship it"])
        #expect(again.visibleTasks[1].done)
    }

    @Test func pendingSaveLandsWithoutAnExplicitFlush() async throws {
        let (module, directory) = await makeModule()
        module.currentText = "autosaved"
        try await Task.sleep(for: NotesModule.saveDelay)
        // The coalesced save lands on its own; wait for the file rather than a fixed time.
        let file = directory.appending(path: "notes.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
        let (again, _) = await makeModule(directory)
        #expect(again.currentText == "autosaved")
    }

    @Test func blankNotesAreDroppedWhenMovingOn() async {
        let (module, _) = await makeModule()
        module.currentText = "first"
        module.newNote()
        module.currentText = "  "
        module.newNote()
        #expect(module.notes.map(\.text) == ["first"])
    }

    @Test func pinSelectDeleteAndSearch() async {
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (module, _) = await makeModule(now: { clock })
        module.currentText = "alpha"
        clock.addTimeInterval(60)
        module.newNote()
        module.currentText = "beta"
        let alpha = module.notes.first { $0.text == "alpha" }!
        module.togglePin(alpha)
        #expect(module.visibleNotes.map(\.text) == ["alpha", "beta"])
        module.query = "bet"
        #expect(module.visibleNotes.map(\.text) == ["beta"])
        module.query = ""
        module.select(alpha)
        #expect(module.currentText == "alpha")
        module.delete(alpha)
        #expect(module.currentText == "beta")
    }

    @Test func tasksAddCompleteReopenRenameMoveDelete() async {
        let (module, _) = await makeModule()
        module.addTask("a"); module.addTask("b"); module.addTask("c"); module.addTask("   ")
        #expect(module.visibleTasks.map(\.title) == ["a", "b", "c"])

        module.toggle(module.visibleTasks[0])
        #expect(module.visibleTasks.map(\.title) == ["b", "c", "a"])
        module.addTask("d") // above the finished one
        #expect(module.visibleTasks.map(\.title) == ["b", "c", "d", "a"])

        module.toggle(module.visibleTasks[3]) // reopened: back in its old place
        #expect(module.visibleTasks.map(\.title) == ["a", "b", "c", "d"])

        module.rename(module.visibleTasks[0], to: "  b2 ")
        module.rename(module.visibleTasks[0], to: " ") // ignored
        #expect(module.visibleTasks[0].title == "b2")

        module.moveTasks(from: [0], to: 3)
        #expect(module.visibleTasks.map(\.title) == ["b", "c", "b2", "d"])
        module.move(module.visibleTasks[2], by: -1)
        #expect(module.visibleTasks.map(\.title) == ["b", "b2", "c", "d"])

        module.deleteTask(module.visibleTasks[0])
        module.toggle(module.visibleTasks[0])
        module.clearCompleted()
        #expect(module.visibleTasks.map(\.title) == ["c", "d"])
    }

    @Test func dueDates() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (module, _) = await makeModule(now: { now })
        module.addTask("x")
        module.setDue(module.tasks[0], inDays: 1)
        #expect(module.tasks[0].due == Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)))
        module.setDue(module.tasks[0], inDays: nil)
        #expect(module.tasks[0].due == nil)
    }

    @Test func corruptFileIsKeptAsideNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orilio-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: directory.appending(path: "notes.json"))
        let (module, _) = await makeModule(directory)
        #expect(module.notes.isEmpty)
        let backup = try #require(module.recoveredBackup)
        let kept = try String(contentsOf: directory.appending(path: backup), encoding: .utf8)
        #expect(kept == "{ broken")
    }

    @Test func fileFromANewerVersionIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orilio-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = #"{"version": 99, "notes": [], "tasks": []}"#
        try Data(future.utf8).write(to: directory.appending(path: "notes.json"))
        let (module, _) = await makeModule(directory)
        #expect(module.recoveredBackup != nil)
    }

    @Test func nothingIsSavedBeforeLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orilio-notes-\(UUID().uuidString)")
        let module = NotesModule(store: NotesStore(directory: directory))
        module.currentText = "typed before load"
        await module.saveNow()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "notes.json").path))
    }

    @Test func taskChangesReachTheSyncAdapter() async throws {
        actor Recorder: TaskSyncAdapter {
            var upserts: [String] = []
            var deletes = 0
            func upsert(_ task: TaskItem) { upserts.append(task.title) }
            func delete(_ id: UUID) { deletes += 1 }
        }
        let (module, _) = await makeModule()
        let recorder = Recorder()
        module.sync = recorder
        module.addTask("a")
        module.deleteTask(module.tasks[0])
        // The adapter is called from detached tasks: wait for the result, not a fixed time.
        for _ in 0..<100 where await recorder.deletes == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await recorder.upserts == ["a"])
        #expect(await recorder.deletes == 1)
    }
}

/// QA-0 P0: a notes file that exists but can't be read used to load as "no notes", and the next save
/// wrote the empty list over it.
@MainActor
struct NotesUnreadableFileTests {
    @Test func anUnreadableFileIsNeverWrittenOver() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orilio-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = NotesModule(store: NotesStore(directory: directory))
        await first.load()
        first.newNote()
        first.currentText = "Keep me"
        await first.saveNow()
        let file = directory.appending(path: "notes.json")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path) // can't be read
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let second = NotesModule(store: NotesStore(directory: directory))
        await second.load()
        second.newNote()
        second.currentText = "Typed while the file was unreadable"
        await second.saveNow()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }
}

