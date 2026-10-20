import AppKit
import SwiftUI

struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case dot(UInt32)
    }
    let id: String
    let icon: Icon
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var shortcut: String? = nil
    let action: () -> Void
}

/// Remembers the sections built for the current query. The view body and the key monitor both
/// need them on every keystroke, and building them runs a search over every note.
private final class PaletteSections {
    var query: String?
    var sections: [(String, [PaletteItem])] = []
}

/// ⌘K: search notes, jump anywhere, run any command.
struct CommandPalette: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var selection = 0
    @State private var monitor: Any?
    @State private var listHeight: CGFloat = 0
    @State private var built = PaletteSections()
    @FocusState private var focused: Bool

    var body: some View {
        let style = app.chromeStyle
        let sections = currentSections()
        let flat = sections.flatMap(\.1)

        ZStack(alignment: .top) {
            Color.black.opacity(style.theme.isDark ? 0.35 : 0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(style.tertiary)
                    TextField("", text: $query, prompt: Text("Search notes, or type a command…").foregroundStyle(style.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundStyle(style.text)
                        .focused($focused)
                        .onChange(of: query) { selection = 0 }
                    Text("esc")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(style.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(style.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Rectangle().fill(style.tertiary.opacity(0.18)).frame(height: 0.5)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if flat.isEmpty {
                                Text("No matches")
                                    .font(.system(size: 13))
                                    .foregroundStyle(style.tertiary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 28)
                            }
                            ForEach(sections, id: \.0) { title, items in
                                Text(title.uppercased())
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(0.6)
                                    .foregroundStyle(style.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 3)
                                ForEach(items) { item in
                                    let index = flat.firstIndex { $0.id == item.id } ?? 0
                                    PaletteRow(item: item, isSelected: index == selection, style: style)
                                        .id(item.id)
                                        .onTapGesture { run(item) }
                                        .onHover { if $0 { selection = index } }
                                }
                            }
                        }
                        .padding(6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .frame(height: min(max(listHeight, 44), 400))
                    .onChange(of: selection) { _, new in
                        if flat.indices.contains(new) { proxy.scrollTo(flat[new].id) }
                    }
                }
            }
            .frame(width: 580)
            .background(style.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(style.tertiary.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(style.theme.isDark ? 0.55 : 0.2), radius: 40, y: 18)
            .padding(.top, 86)
        }
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let items = currentSections().flatMap(\.1)
            switch event.keyCode {
            case 125: // down
                selection = min(selection + 1, max(items.count - 1, 0)); return nil
            case 126: // up
                selection = max(selection - 1, 0); return nil
            case 36, 76: // return
                if items.indices.contains(selection) { run(items[selection]) }
                return nil
            case 53: // escape
                close(); return nil
            default:
                if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "n" {
                    selection = min(selection + 1, max(items.count - 1, 0)); return nil
                }
                if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "p" {
                    selection = max(selection - 1, 0); return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func close() {
        app.isPaletteOpen = false
        app.focusEditorSoon()
    }

    private func run(_ item: PaletteItem) {
        app.isPaletteOpen = false
        item.action()
        if !app.isStylePanelOpen { app.focusEditorSoon() }
    }

    // MARK: Items

    private func currentSections() -> [(String, [PaletteItem])] {
        if built.query != query {
            built.sections = buildSections()
            built.query = query
        }
        return built.sections
    }

    private func buildSections() -> [(String, [PaletteItem])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let store = app.store
        var sections: [(String, [PaletteItem])] = []

        // #tag → tag results only
        if q.hasPrefix("#") {
            let needle = LibraryStore.normalizeTag(q)
            let tags = store.allTags.filter { needle.isEmpty || $0.hasPrefix(needle) }
            let items = tags.map { tag in
                PaletteItem(id: "tag-\(tag)", icon: .symbol("number"), title: tag,
                            detail: "\(store.notes(taggedWith: tag).count)") { app.toggleDrawer(.tag(tag)) }
            }
            return items.isEmpty ? [] : [("Tags", items)]
        }

        let noteItems: [PaletteItem] = store.search(q, limit: q.isEmpty ? 6 : 12).map { hit in
            let nb = store.notebook(hit.note.notebookID)
            return PaletteItem(id: "note-\(hit.note.id)", icon: .dot(nb?.color.hex ?? 0x999999),
                               title: hit.note.displayTitle,
                               subtitle: hit.snippet ?? (hit.note.preview.isEmpty ? nil : hit.note.preview),
                               detail: nb?.name) {
                app.open(hit.note.id, newTab: NSEvent.modifierFlags.contains(.command))
                app.focusEditorSoon()
            }
        }

        let commands = allCommands().filter { matches($0.title, q) }

        if q.isEmpty {
            if !noteItems.isEmpty { sections.append(("Recent", noteItems)) }
            sections.append(("Actions", Array(commands.prefix(6))))
        } else {
            if !noteItems.isEmpty { sections.append(("Notes", noteItems)) }
            if !commands.isEmpty { sections.append(("Commands", Array(commands.prefix(10)))) }
            let create = PaletteItem(id: "create", icon: .symbol("plus"), title: "New note “\(q)”", shortcut: nil) {
                let note = store.createNote(in: app.contextNotebookID, style: app.defaultStyle)
                store.updateDocument(note.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: q)]),
                                                                  Block(kind: .body, runs: [])]))
                app.open(note.id, newTab: true)
                app.focusEditorSoon()
            }
            sections.append(("Create", [create]))
        }
        return sections
    }

    private func matches(_ title: String, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let t = title.lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { t.contains($0) }
    }

    private func allCommands() -> [PaletteItem] {
        let store = app.store
        var items: [PaletteItem] = [
            PaletteItem(id: "quick", icon: .symbol("square.and.pencil"), title: "Quick note", shortcut: "⌥Space") { app.showQuickCapture?() },
            PaletteItem(id: "new", icon: .symbol("square.and.pencil"), title: "New note", shortcut: "⌘N") { app.newNote() },
            PaletteItem(id: "look", icon: .symbol("textformat"), title: "Customize look", shortcut: "⌥⌘L") {
                withAnimation(.snappy(duration: 0.25)) { app.isStylePanelOpen = true }
            },
            PaletteItem(id: "chat", icon: .symbol("bubble.left.and.text.bubble.right"), title: "Chat about this note", shortcut: "⌥⌘J") {
                app.isChatOpen = true
            },
            PaletteItem(id: "all", icon: .symbol("square.grid.2x2"), title: "Browse all notes", shortcut: "⇧⌘A") { app.toggleDrawer(.all) },
            PaletteItem(id: "notebook-new", icon: .symbol("plus.circle"), title: "New notebook", shortcut: nil) { newNotebookPrompt() },
        ]

        if let note = app.activeNote {
            items.append(PaletteItem(id: "widget", icon: .symbol("rectangle.inset.filled"), title: "Show this note in widget") { app.selectWidgetNote?() })
            items.append(PaletteItem(id: "pin", icon: .symbol(note.pinned ? "pin.slash" : "pin"),
                                     title: note.pinned ? "Unpin note" : "Pin note") { store.togglePin(note.id) })
            for kind: BlockKind in [.checklist, .bullet, .numbered, .heading1, .heading2, .quote, .callout, .code, .body] {
                items.append(PaletteItem(id: "block-\(kind.rawValue)", icon: .symbol(kind.symbol),
                                         title: "Turn into \(kind.displayName.lowercased())") {
                    app.focusEditorSoon()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { app.activeEditor?.setBlockKind(kind) }
                })
            }
            for kind in [BlockKind.gallery, .table, .board, .columns, .sketch] {
                items.append(PaletteItem(id: "insert-\(kind.rawValue)", icon: .symbol(kind.symbol), title: "Insert \(kind.displayName.lowercased())") {
                    app.focusEditorSoon()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { app.activeEditor?.insertRichBlock(kind) }
                })
            }
            items.append(PaletteItem(id: "scan", icon: .symbol("doc.viewfinder"), title: "Scan from iPhone") {
                app.focusEditorSoon()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { app.activeEditor?.showScanMenu() }
            })
            items.append(PaletteItem(id: "list-board", icon: .symbol("rectangle.split.3x1"), title: "Turn list into board") {
                app.focusEditorSoon()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { app.activeEditor?.convertListToBoard() }
            })
            for nb in store.sortedNotebooks where nb.id != note.notebookID {
                items.append(PaletteItem(id: "move-\(nb.id)", icon: .dot(nb.color.hex), title: "Move to \(nb.name)") {
                    store.move(note.id, to: nb.id)
                })
            }
            for theme in Theme.presets {
                items.append(PaletteItem(id: "theme-\(theme.id)", icon: .symbol("paintpalette"), title: "Theme: \(theme.name)") {
                    app.updateActiveStyle { $0.themeID = theme.id }
                })
            }
            items.append(PaletteItem(id: "divider", icon: .symbol("minus"), title: "Insert divider", shortcut: "⌥⌘-") {
                app.focusEditorSoon()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { app.activeEditor?.insertDivider() }
            })
            items.append(PaletteItem(id: "delete", icon: .symbol("trash"), title: "Delete note") { app.delete(note.id) })
        }

        for nb in store.sortedNotebooks {
            items.append(PaletteItem(id: "open-\(nb.id)", icon: .dot(nb.color.hex), title: "Open \(nb.name)",
                                     detail: "\(store.count(in: nb.id))") { app.toggleDrawer(.notebook(nb.id)) })
        }
        items.append(PaletteItem(id: "pinned", icon: .symbol("pin"), title: "Open pinned notes") { app.toggleDrawer(.pinned) })
        for a in AppearanceSetting.allCases {
            items.append(PaletteItem(id: "appearance-\(a.rawValue)", icon: .symbol(a == .dark ? "moon" : a == .light ? "sun.max" : "circle.lefthalf.filled"),
                                     title: "Appearance: \(a.label)") { app.appearance = a })
        }
        for accent in AccentColor.allCases {
            items.append(PaletteItem(id: "accent-\(accent.rawValue)", icon: .dot(accent.hex), title: "App accent: \(accent.label)") {
                app.appAccent = accent
            })
        }
        return items
    }

    private func newNotebookPrompt() {
        let alert = NSAlert()
        alert.messageText = "New notebook"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let nb = app.store.createNotebook(name: name)
            app.toggleDrawer(.notebook(nb.id))
        }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    let style: ResolvedStyle

    var body: some View {
        HStack(spacing: 11) {
            Group {
                switch item.icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isSelected ? style.text : style.tertiary.mix(with: style.text, by: 0.3))
                case .dot(let hex):
                    Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(style.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(style.tertiary).lineLimit(1)
            }
            if let shortcut = item.shortcut {
                Text(shortcut).font(.system(size: 11.5, design: .rounded)).foregroundStyle(style.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, item.subtitle == nil ? 8 : 6)
        .background(isSelected ? style.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}
