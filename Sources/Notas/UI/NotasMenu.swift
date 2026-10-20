import AppKit
import SwiftUI

@MainActor
struct NotasMenu: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    private var app: AppState { delegate.app }
    private var capture: QuickCaptureController? { delegate.quickCapture }

    var body: some View {
        let recentNotes = app.store.search("", limit: 5).map(\.note)
        quickNoteButton

        Section("Recent Notes") {
            if recentNotes.isEmpty {
                Text("No notes yet")
            } else {
                ForEach(recentNotes) { note in
                    Button(recentTitle(for: note, among: recentNotes)) { openRecent(note.id) }
                        .accessibilityLabel(recentAccessibilityLabel(for: note))
                        .accessibilityHint("Opens in Notas")
                        .help(note.displayTitle)
                }
            }

            Button("Search Notes…") { searchNotes() }
        }

        Divider()
        Button("Open Notas") { showMainWindow() }
        shortcutMenu
        Divider()
        Button("Quit Notas") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var quickNoteButton: some View {
        let button = Button { capture?.show() } label: {
            Label(captureTitle, systemImage: "square.and.pencil")
        }
        .disabled(capture == nil)

        if capture?.model.shortcutError == nil, let shortcut = capture?.model.shortcut {
            switch shortcut {
            case .optionSpace:
                button.keyboardShortcut(.space, modifiers: .option)
            case .controlOptionSpace:
                button.keyboardShortcut(.space, modifiers: [.control, .option])
            case .off:
                button
            }
        } else {
            button
        }
    }

    @ViewBuilder
    private var shortcutMenu: some View {
        Menu("Quick Note Shortcut") {
            if let capture {
                ForEach(CaptureShortcut.allCases) { shortcut in
                    Button {
                        capture.setShortcut(shortcut)
                    } label: {
                        if capture.model.shortcut == shortcut {
                            Label(shortcut.menuLabel, systemImage: "checkmark")
                        } else {
                            Text(shortcut.menuLabel)
                        }
                    }
                }
                if capture.model.shortcutError != nil {
                    Divider()
                    Text("Shortcut unavailable")
                }
            } else {
                Text("Quick capture unavailable")
            }
        }
    }

    private var captureTitle: String {
        let hasDraft = capture?.model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasDraft ? "Continue Quick Note…" : "Quick Note…"
    }

    private func recentTitle(for note: Note, among recentNotes: [Note]) -> String {
        let matches = recentNotes.filter { $0.displayTitle == note.displayTitle }
        guard matches.count > 1, let notebook = app.store.notebook(note.notebookID) else { return note.displayTitle }
        return "\(note.displayTitle) — \(notebook.name)"
    }

    private func recentAccessibilityLabel(for note: Note) -> String {
        guard let notebook = app.store.notebook(note.notebookID) else { return "\(note.displayTitle), recently edited note" }
        return "\(note.displayTitle), \(notebook.name), recently edited note"
    }

    private func openRecent(_ id: UUID) {
        guard app.store.notes[id] != nil else {
            showMainWindow()
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "This note is no longer available."
                alert.runModal()
            }
            return
        }
        app.drawer = nil
        app.isPaletteOpen = false
        app.open(id, newTab: true)
        showMainWindow()
        app.focusEditorSoon()
    }

    private func searchNotes() {
        app.isPaletteOpen = true
        showMainWindow()
    }

    private func showMainWindow() {
        delegate.showMainWindow { openWindow(id: "main") }
    }
}

private extension CaptureShortcut {
    var menuLabel: String {
        switch self {
        case .optionSpace: "Option–Space"
        case .controlOptionSpace: "Control–Option–Space"
        case .off: "Off"
        }
    }
}
