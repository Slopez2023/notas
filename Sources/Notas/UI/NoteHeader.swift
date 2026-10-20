import SwiftUI

/// The quiet line above the title: notebook, last edited, and tags.
struct NoteHeader: View {
    let noteID: UUID
    @Environment(AppState.self) private var app
    @State private var isAddingTag = false
    @State private var tagDraft = ""
    @FocusState private var tagFieldFocused: Bool

    var body: some View {
        if let note = app.store.notes[noteID] {
            let style = app.resolvedStyle(for: note)
            HStack(spacing: 10) {
                notebookMenu(note: note, style: style)
                Text(Self.stamp(note.modified))
                ForEach(note.tags, id: \.self) { tag in
                    TagChip(tag: tag, style: style) {
                        app.toggleDrawer(.tag(tag))
                    } onRemove: {
                        app.store.removeTag(tag, from: noteID)
                    }
                }
                if isAddingTag {
                    TextField("tag", text: $tagDraft)
                        .textFieldStyle(.plain)
                        .focused($tagFieldFocused)
                        .frame(width: 90)
                        .onSubmit(commitTag)
                        .onExitCommand { isAddingTag = false; tagDraft = "" }
                        .onChange(of: tagFieldFocused) { _, focused in if !focused { commitTag() } }
                } else {
                    Button {
                        isAddingTag = true
                        DispatchQueue.main.async { tagFieldFocused = true }
                    } label: {
                        Text(note.tags.isEmpty ? "+ TAG" : "+")
                    }
                    .buttonStyle(.plain)
                    .opacity(0.8)
                    .help("Add a tag")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(style.tertiary)
            .lineLimit(1)
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func notebookMenu(note: Note, style: ResolvedStyle) -> some View {
        let notebook = app.store.notebook(note.notebookID)
        return Menu {
            Section("Move to") {
                ForEach(app.store.sortedNotebooks) { nb in
                    Button {
                        app.store.move(noteID, to: nb.id)
                    } label: {
                        if nb.id == note.notebookID { Label(nb.name, systemImage: "checkmark") } else { Text(nb.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: notebook?.color.hex ?? 0x999999)).frame(width: 7, height: 7)
                Text((notebook?.name ?? "Notebook").uppercased())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move to another notebook")
    }

    private func commitTag() {
        let tag = tagDraft
        tagDraft = ""
        isAddingTag = false
        app.store.addTag(tag, to: noteID)
    }

    static func stamp(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "TODAY · \(time)".uppercased() }
        if cal.isDateInYesterday(date) { return "YESTERDAY · \(time)".uppercased() }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: .now)
        let day = sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day) · \(time)".uppercased()
    }
}

struct TagChip: View {
    let tag: String
    let style: ResolvedStyle
    var onTap: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text("#\(tag)")
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .textCase(nil)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(style.secondary)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { Button("Remove Tag", role: .destructive, action: onRemove) }
    }
}
