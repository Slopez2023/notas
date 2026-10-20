import SwiftUI

/// Slides out from the rail with the notes in a notebook (or pinned, all, a tag).
struct NotebookDrawer: View {
    let content: DrawerContent
    @Environment(AppState.self) private var app

    private var title: String {
        switch content {
        case .all: "All notes"
        case .pinned: "Pinned"
        case .notebook(let id): app.store.notebook(id)?.name ?? "Notebook"
        case .tag(let tag): "#\(tag)"
        }
    }

    private var notes: [Note] {
        switch content {
        case .all: app.store.notes(in: nil)
        case .pinned: app.store.pinnedNotes
        case .notebook(let id): app.store.notes(in: id)
        case .tag(let tag): app.store.notes(taggedWith: tag)
        }
    }

    private var dotColor: Color? {
        if case .notebook(let id) = content, let nb = app.store.notebook(id) { return Color(hex: nb.color.hex) }
        return nil
    }

    var body: some View {
        let style = app.chromeStyle
        let notes = self.notes
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let dotColor { Circle().fill(dotColor).frame(width: 9, height: 9) }
                Text(title)
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                Text("\(notes.count)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(style.tertiary)
                Spacer()
                Button {
                    if case .notebook(let id) = content { app.newNote(in: id) } else { app.newNote() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.tertiary.mix(with: style.text, by: 0.4))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New note here")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if notes.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing here yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.secondary)
                    Text("Press ⌘N to start a note.")
                        .font(.system(size: 12))
                        .foregroundStyle(style.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(Self.group(notes), id: \.0) { section, items in
                            Text(section.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(style.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(items) { note in
                                DrawerRow(note: note, style: style, showNotebook: !isNotebookDrawer)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 300)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(style.tertiary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(style.theme.isDark ? 0.5 : 0.14), radius: 30, y: 12)
    }

    private var isNotebookDrawer: Bool {
        if case .notebook = content { return true }
        return false
    }

    static func group(_ notes: [Note]) -> [(String, [Note])] {
        let cal = Calendar.current
        var buckets: [(String, [Note])] = []
        func add(_ key: String, _ note: Note) {
            if let i = buckets.firstIndex(where: { $0.0 == key }) { buckets[i].1.append(note) } else { buckets.append((key, [note])) }
        }
        for note in notes {
            if note.pinned { add("Pinned", note); continue }
            let d = note.modified
            if cal.isDateInToday(d) { add("Today", note) }
            else if cal.isDateInYesterday(d) { add("Yesterday", note) }
            else if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { add("This week", note) }
            else if cal.isDate(d, equalTo: .now, toGranularity: .year) { add(d.formatted(.dateTime.month(.wide)), note) }
            else { add(d.formatted(.dateTime.year()), note) }
        }
        return buckets
    }
}

struct DrawerRow: View {
    let note: Note
    let style: ResolvedStyle
    let showNotebook: Bool
    @Environment(AppState.self) private var app
    @State private var hovering = false

    var body: some View {
        let isActive = app.activeNoteID == note.id
        let notebook = app.store.notebook(note.notebookID)
        let preview = note.preview
        Button {
            let newTab = NSEvent.modifierFlags.contains(.command)
            app.open(note.id, newTab: newTab)
            withAnimation(.snappy(duration: 0.25)) { app.drawer = nil }
            app.focusEditorSoon()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(style.accentColor)
                    }
                    Text(note.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(style.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.shortDate(note.modified))
                        .font(.system(size: 10.5))
                        .foregroundStyle(style.tertiary)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(style.secondary.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if showNotebook, let notebook {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: notebook.color.hex)).frame(width: 6, height: 6)
                        Text(notebook.name).font(.system(size: 10.5)).foregroundStyle(style.tertiary)
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? style.accentColor.opacity(0.16) : (hovering ? style.background.opacity(0.55) : .clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open in New Tab") { app.open(note.id, newTab: true); app.drawer = nil }
            Button(note.pinned ? "Unpin" : "Pin") { app.store.togglePin(note.id) }
            Menu("Move to") {
                ForEach(app.store.sortedNotebooks) { nb in
                    Button(nb.name) { app.store.move(note.id, to: nb.id) }.disabled(nb.id == note.notebookID)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { app.delete(note.id) }
        }
    }

    static func shortDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}
