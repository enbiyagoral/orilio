import AppKit
import SwiftUI

// Values follow the M3 hub design: a 300 pt note (radius 16, padding 14) on the left; tasks with
// 20 pt round checks in 40 pt rows and a 38 pt "add" field (radius 12) on the right.
private enum Design {
    static let field = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let ink = Color(red: 0, green: 0.078, blue: 0.051) // #00140D, on the accent
}

/// The Notes and tasks module in the island.
struct NotesPanel: View {
    @Bindable var module: NotesModule

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                NotesHeader(module: module)
                if module.browsing {
                    NotesList(module: module)
                } else {
                    NoteEditor(module: module)
                }
            }
            .frame(width: 300)
            TaskList(module: module)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Typing needs Orilio to be the active app; fields take focus only when clicked.
private struct ActivateOnFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { if focused { NSApp.activate() } }
            .tint(.white) // a white caret, not the system's blue
    }
}

private struct NotesHeader: View {
    let module: NotesModule

    var body: some View {
        HStack(spacing: 4) {
            Text(module.browsing ? "All notes" : "Quick note").font(.system(size: 13, weight: .semibold))
            Spacer()
            SmallButton(symbol: module.browsing ? "square.and.pencil" : "list.bullet",
                        label: module.browsing ? "Back to the note" : "All notes") { module.browsing.toggle() }
            SmallButton(symbol: "plus", label: "New note") { module.newNote() }
            Menu {
                if let note = module.currentNote, !module.browsing {
                    Button(note.pinned ? "Unpin Note" : "Pin Note") { module.togglePin(note) }
                    Button("Copy Note") { module.copy(note) }
                    Button("Delete Note", role: .destructive) { module.delete(note) }
                    Divider()
                }
                Button("Export Notes and Tasks…") { module.export() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 24, height: 22)
            .accessibilityLabel("Note actions")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

private struct SmallButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NoteEditor: View {
    @Bindable var module: NotesModule

    var body: some View {
        TextEditor(text: $module.currentText)
            .font(.system(size: 13))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .autocorrectionDisabled()
            .modifier(ActivateOnFocus())
            // The design's 14 pt on every side: 14 above, 9 + the text container's own 5 at the sides,
            // so the caret and the first line start exactly where the placeholder does.
            .padding(EdgeInsets(top: 14, leading: 9, bottom: 14, trailing: 9))
            .overlay(alignment: .topLeading) {
                if module.currentText.isEmpty {
                    Text("Type to capture a thought…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .background(Design.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Design.hairline))
            .accessibilityLabel("Quick note")
    }
}

private struct NotesList: View {
    @Bindable var module: NotesModule

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                TextField("Search notes", text: $module.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .modifier(ActivateOnFocus())
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Design.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            let notes = module.visibleNotes
            if notes.isEmpty {
                Text(module.notes.isEmpty ? "No notes yet." : "Nothing matches that search.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(notes) { note in NoteRow(note: note, current: note.id == module.currentNoteID, module: module) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let current: Bool
    let module: NotesModule

    var body: some View {
        Button { module.select(note) } label: {
            HStack(spacing: 8) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
                Text(note.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 6)
                Text(note.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(current ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(note.pinned ? "Unpin" : "Pin") { module.togglePin(note) }
            Button("Copy") { module.copy(note) }
            Divider()
            Button("Delete", role: .destructive) { module.delete(note) }
        }
    }
}

private struct TaskList: View {
    @Bindable var module: NotesModule
    @State private var draft = ""
    @State private var editing: UUID?
    @FocusState private var adding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !module.tasks.isEmpty {
                    Text(module.doneText).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 6)

            if NotesCardState.allDone(module.tasks) {
                StatusCard(tone: .good, symbol: "checkmark.circle", title: "All done for today",
                           detail: "Nice. Anything else on your mind?",
                           primary: .init("Add a task") {
                               NSApp.activate()
                               adding = true
                           })
            } else {
            // Due labels say "Today" or "Tomorrow", so they follow the date.
            TimelineView(.everyMinute) { context in
                List {
                    ForEach(module.visibleTasks) { task in
                        TaskRow(task: task, now: context.date, module: module, editing: $editing)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .moveDisabled(task.done)
                    }
                    .onMove { module.moveTasks(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 40)
            }
            }

            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                TextField("Add a task, press Return", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($adding)
                    .onChange(of: adding) { if adding { NSApp.activate() } }
                    .tint(.white)
                    .onSubmit {
                        module.addTask(draft)
                        draft = ""
                    }
                    .accessibilityLabel("New task")
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Design.hairline))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let now: Date
    let module: NotesModule
    @Binding var editing: UUID?
    @State private var title = ""

    var body: some View {
        HStack(spacing: 10) {
            Button { module.toggle(task) } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(task.done ? 0 : 0.35), lineWidth: 1.5)
                        .background(Circle().fill(task.done ? accent(.rest) : .clear))
                    if task.done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Design.ink)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.title)
            .accessibilityValue(task.done ? "Done" : "Not done")
            .accessibilityAddTraits(.isToggle)

            if editing == task.id {
                TextField("Task", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .modifier(ActivateOnFocus())
                    .onSubmit { commit() }
                    .onExitCommand { editing = nil }
                    .onAppear { title = task.title }
            } else {
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(task.done ? .white.opacity(0.45) : .white)
                    .strikethrough(task.done, color: .white.opacity(0.45))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = task.id }
            }
            if let due = NotesPolicy.dueText(task.due, now: now), !task.done {
                Text(due)
                    .font(.system(size: 11.5))
                    .foregroundStyle(NotesPolicy.isOverdue(task, now: now) ? Color(red: 1, green: 0.48, blue: 0.43) : .white.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background(module.selectedTaskID == task.id ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(module.selectedTaskID == task.id ? 0.85 : 0), lineWidth: 1.5))
        .contextMenu {
            Button("Rename") { editing = task.id }
            Menu("Due") {
                Button("Today") { module.setDue(task, inDays: 0) }
                Button("Tomorrow") { module.setDue(task, inDays: 1) }
                Button("Next Week") { module.setDue(task, inDays: 7) }
                Button("No Due Date") { module.setDue(task, inDays: nil) }
            }
            if !task.done {
                Button("Move Up") { module.move(task, by: -1) }
                Button("Move Down") { module.move(task, by: 1) }
            }
            Divider()
            Button("Delete", role: .destructive) { module.deleteTask(task) }
            Button("Clear Completed") { module.clearCompleted() }
        }
    }

    private func commit() {
        module.rename(task, to: title)
        editing = nil
    }
}
