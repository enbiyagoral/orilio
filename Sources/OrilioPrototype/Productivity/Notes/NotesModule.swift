import AppKit
import Observation

/// Quick notes and tasks. Every edit lands in memory at once and is saved shortly after, so
/// closing the island or switching modules never loses text; quitting flushes the last save.
@MainActor @Observable
final class NotesModule {
    private(set) var notes: [Note] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var currentNoteID: UUID?
    /// The panel shows the notes list (with search) instead of the editor.
    var browsing = false
    var query = ""
    /// The unreadable file Orilio kept aside on the last load, if any.
    private(set) var recoveredBackup: String?

    @ObservationIgnored private let store: NotesStore
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored var sync: (any TaskSyncAdapter)?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    static let saveDelay: Duration = .milliseconds(500)

    init(store: NotesStore = NotesStore(), now: @escaping @MainActor () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func load() async {
        switch await store.load() {
        case .loaded(let file):
            notes = file.notes
            tasks = file.tasks
        case .recovered(let file, let backup):
            notes = file.notes
            tasks = file.tasks
            recoveredBackup = backup
        }
        loaded = true
        currentNoteID = NotesPolicy.ordered(notes).first?.id
    }

    // MARK: Notes

    var currentNote: Note? { notes.first { $0.id == currentNoteID } }
    var visibleNotes: [Note] { NotesPolicy.search(NotesPolicy.ordered(notes), query) }

    /// The editor's text. Typing into an empty editor creates the note.
    var currentText: String {
        get { currentNote?.text ?? "" }
        set {
            if let index = notes.firstIndex(where: { $0.id == currentNoteID }) {
                guard notes[index].text != newValue else { return }
                notes[index].text = newValue
                notes[index].updatedAt = now()
            } else {
                guard !newValue.isEmpty else { return }
                let note = Note(id: UUID(), text: newValue, createdAt: now(), updatedAt: now(), pinned: false)
                notes.append(note)
                currentNoteID = note.id
            }
            scheduleSave()
        }
    }

    func newNote() {
        dropBlankCurrent()
        currentNoteID = nil // created by the first keystroke
        browsing = false
    }

    func select(_ note: Note) {
        if note.id != currentNoteID { dropBlankCurrent() }
        currentNoteID = note.id
        browsing = false
    }

    func togglePin(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].pinned.toggle()
        scheduleSave()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if currentNoteID == note.id { currentNoteID = NotesPolicy.ordered(notes).first?.id }
        scheduleSave()
    }

    func copy(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    /// A note left empty isn't kept when the user moves on.
    private func dropBlankCurrent() {
        guard let current = currentNote, current.isBlank, !current.pinned else { return }
        notes.removeAll { $0.id == current.id }
        scheduleSave()
    }

    // MARK: Tasks

    var visibleTasks: [TaskItem] { NotesPolicy.ordered(tasks) }
    var doneText: String { "\(tasks.filter(\.done).count) of \(tasks.count) done" }

    func addTask(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = TaskItem(id: UUID(), title: title, done: false, createdAt: now())
        // New tasks go after the last open one, above the finished ones.
        tasks.insert(task, at: tasks.lastIndex { !$0.done }.map { $0 + 1 } ?? 0)
        changed(task)
    }

    func toggle(_ task: TaskItem) {
        update(task.id) {
            $0.done.toggle()
            $0.completedAt = $0.done ? now() : nil
        }
    }

    func rename(_ task: TaskItem, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(task.id) { $0.title = title }
    }

    func setDue(_ task: TaskItem, inDays days: Int?) {
        let calendar = Calendar.current
        update(task.id) { item in
            item.due = days.flatMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now())) }
        }
    }

    func deleteTask(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        scheduleSave()
        if let sync { Task { try? await sync.delete(task.id) } }
    }

    func clearCompleted() {
        let done = tasks.filter(\.done)
        tasks.removeAll(where: \.done)
        scheduleSave()
        if let sync { Task { for task in done { try? await sync.delete(task.id) } } }
    }

    /// Reorders open tasks; positions are in `visibleTasks`. Finished tasks don't move.
    func moveTasks(from source: IndexSet, to destination: Int) {
        var open = tasks.filter { !$0.done }
        guard source.allSatisfy(open.indices.contains) else { return }
        open.move(fromOffsets: source, toOffset: min(destination, open.count))
        tasks = open + tasks.filter(\.done)
        scheduleSave()
    }

    /// One step up or down among the open tasks (the keyboard and VoiceOver path for reordering).
    func move(_ task: TaskItem, by offset: Int) {
        let open = tasks.filter { !$0.done }
        guard let index = open.firstIndex(where: { $0.id == task.id }), open.indices.contains(index + offset) else { return }
        moveTasks(from: [index], to: offset > 0 ? index + offset + 1 : index + offset)
    }

    private func update(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        changed(tasks[index])
    }

    private func changed(_ task: TaskItem) {
        scheduleSave()
        if let sync { Task { try? await sync.upsert(task) } }
    }

    // MARK: Saving and export

    private var contents: NotesFile { NotesFile(notes: notes, tasks: tasks) }

    private func scheduleSave() {
        guard loaded else { return } // never overwrite a file that hasn't been read yet
        pendingSave?.cancel()
        let contents = contents
        pendingSave = Task { [store] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            try? await store.save(contents)
        }
    }

    func saveNow() async {
        pendingSave?.cancel()
        guard loaded else { return }
        try? await store.save(contents)
    }

    var markdown: String { NotesPolicy.markdown(notes: notes.filter { !$0.isBlank }, tasks: tasks) }

    /// Asks where to save a Markdown file with every note and task.
    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orilio Notes \(now().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
