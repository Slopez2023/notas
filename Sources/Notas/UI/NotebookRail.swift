import SwiftUI

/// Notebooks as a column of colored dots. Hover to see names; click to browse.
struct NotebookRail: View {
    @Environment(AppState.self) private var app
    @State private var expanded = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let style = app.chromeStyle
        GeometryReader { bounds in
            VStack(alignment: .leading, spacing: 2) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        RailRow(expanded: expanded, style: style, isSelected: app.drawer == .all,
                                label: "All notes", count: app.store.notes.count) {
                            Image(systemName: "square.grid.2x2.fill").font(.system(size: 9.5))
                        } action: { app.toggleDrawer(.all) }

                        RailRow(expanded: expanded, style: style, isSelected: app.drawer == .pinned,
                                label: "Pinned", count: app.store.pinnedNotes.count) {
                            Image(systemName: "pin.fill").font(.system(size: 9.5))
                        } action: { app.toggleDrawer(.pinned) }

                        Rectangle().fill(style.tertiary.opacity(0.25)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 4)

                        ForEach(app.store.sortedNotebooks) { notebook in
                            let selected = app.drawer == .notebook(notebook.id)
                            let current = app.activeNote?.notebookID == notebook.id
                            RailRow(expanded: expanded, style: style, isSelected: selected,
                                    label: notebook.name, count: app.store.count(in: notebook.id)) {
                                Circle()
                                    .fill(Color(hex: notebook.color.hex))
                                    .frame(width: 9, height: 9)
                                    .overlay {
                                        if current && !expanded {
                                            Circle().stroke(Color(hex: notebook.color.hex), lineWidth: 1.5).frame(width: 15, height: 15)
                                        }
                                    }
                            } action: { app.toggleDrawer(.notebook(notebook.id)) }
                            .contextMenu { notebookMenu(notebook) }
                            .popover(isPresented: Binding(get: { app.notebookEditTarget == .rename(notebook.id) }, set: { if !$0 { app.notebookEditTarget = nil } }),
                                     arrowEdge: .trailing) {
                                NotebookEditor(initialName: notebook.name, initialColor: notebook.color, confirmLabel: "Save") { name, color in
                                    app.store.renameNotebook(notebook.id, to: name)
                                    app.store.recolorNotebook(notebook.id, to: color)
                                    app.notebookEditTarget = nil
                                }
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, max(0, bounds.size.height - 46)))
                RailRow(expanded: expanded, style: style, isSelected: false, label: "New notebook", count: nil) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                } action: { app.notebookEditTarget = .new }
                .accessibilityIdentifier("notebook-new")
                .popover(isPresented: Binding(get: { app.notebookEditTarget == .new }, set: { if !$0 { app.notebookEditTarget = nil } }), arrowEdge: .trailing) {
                    NotebookEditor(initialName: "", initialColor: nil, confirmLabel: "Create") { name, color in
                        let nb = app.store.createNotebook(name: name, color: color)
                        app.notebookEditTarget = nil
                        app.toggleDrawer(.notebook(nb.id))
                    }
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .frame(width: expanded ? 196 : 34, alignment: .leading)
            .background(style.surface.opacity(expanded ? 0.98 : 0.85),
                        in: RoundedRectangle(cornerRadius: expanded ? 14 : 17, style: .continuous))
            .shadow(color: .black.opacity(expanded ? (style.theme.isDark ? 0.45 : 0.12) : 0), radius: 18, y: 8)
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.24)) { expanded = hovering || app.notebookEditTarget != nil }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: expanded ? 196 : 34)
        .onChange(of: app.notebookEditTarget, initial: true) { _, value in
            withAnimation(.snappy(duration: 0.24)) { expanded = value != nil }
        }
    }

    @ViewBuilder
    private func notebookMenu(_ notebook: Notebook) -> some View {
        Button("New Note in \(notebook.name)") { app.newNote(in: notebook.id) }
        Divider()
        Button("Rename…") { app.notebookEditTarget = .rename(notebook.id) }
        Menu("Color") {
            ForEach(NotebookColor.allCases) { color in
                Button(color.rawValue.capitalized) { app.store.recolorNotebook(notebook.id, to: color) }
            }
        }
        Button("Move Up") { app.store.moveNotebook(notebook.id, by: -1) }
        Button("Move Down") { app.store.moveNotebook(notebook.id, by: 1) }
        Divider()
        Button("Delete Notebook…", role: .destructive) { confirmDelete(notebook) }
            .disabled(app.store.notebooks.count <= 1)
    }

    private func confirmDelete(_ notebook: Notebook) {
        let count = app.store.count(in: notebook.id)
        let fallback = app.store.sortedNotebooks.first { $0.id != notebook.id }?.name ?? "another notebook"
        let alert = NSAlert()
        alert.messageText = "Delete “\(notebook.name)”?"
        alert.informativeText = count == 0 ? "It's empty." : "Its \(count) note\(count == 1 ? "" : "s") will move to \(fallback)."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            if app.drawer == .notebook(notebook.id) { app.drawer = nil }
            app.store.deleteNotebook(notebook.id)
        }
    }
}

enum NotebookEditTarget: Equatable {
    case new
    case rename(UUID)
}

struct RailRow<Icon: View>: View {
    let expanded: Bool
    let style: ResolvedStyle
    let isSelected: Bool
    let label: String
    let count: Int?
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                    .foregroundStyle(style.tertiary.mix(with: style.text, by: isSelected || hovering ? 0.6 : 0.2))
                    .frame(width: 22, height: 20)
                if expanded {
                    Text(label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(style.text)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    Spacer(minLength: 4)
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(style.tertiary)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.trailing, expanded ? 8 : 0)
            .frame(height: 26)
            .background((isSelected || (hovering && expanded)) ? style.accentColor.opacity(isSelected ? 0.2 : 0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(expanded ? "" : label)
    }
}

/// Name + color picker used for creating and renaming notebooks.
struct NotebookEditor: View {
    let initialName: String
    let initialColor: NotebookColor?
    let confirmLabel: String
    let onConfirm: (String, NotebookColor) -> Void
    @State private var name = ""
    @State private var color: NotebookColor = .coral
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Notebook name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityIdentifier("notebook-create-name")
                .onSubmit(confirm)
            HStack(spacing: 7) {
                ForEach(NotebookColor.allCases) { c in
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 18, height: 18)
                        .overlay { if c == color { Circle().stroke(Color.primary, lineWidth: 2).frame(width: 24, height: 24) } }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                        .onTapGesture { color = c }
                }
            }
            HStack {
                Spacer()
                Button(confirmLabel, action: confirm)
                    .accessibilityIdentifier("notebook-create-confirm")
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            name = initialName
            color = initialColor ?? NotebookColor.allCases.randomElement() ?? .coral
            focused = true
        }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed, color)
    }
}
