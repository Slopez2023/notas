import AppKit
import SwiftUI

/// Hosts the AppKit editor for one note. Recreated per note (keyed by id) so each
/// note gets its own undo history.
struct NoteEditorView: NSViewRepresentable {
    let noteID: UUID
    let style: ResolvedStyle
    @Environment(AppState.self) private var app

    func makeCoordinator() -> Coordinator { Coordinator(noteID: noteID, app: app) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotasTextView.make()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.noteAssets = app.store.assets(for: noteID)
        textView.noteID = noteID
        textView.delegate = coordinator
        textView.onUserEdit = { [weak coordinator] in coordinator?.scheduleSave() }

        let header = NSHostingView(rootView: NoteHeader(noteID: noteID).environment(app))
        header.sizingOptions = []
        textView.headerView = header

        textView.applyStyle(style)
        if let note = app.store.notes[noteID] {
            textView.load(note.document)
        }
        coordinator.lastStyle = style
        app.activeEditor = textView

        // Put the cursor somewhere sensible.
        DispatchQueue.main.async {
            let isNew = textView.string.isEmpty
            textView.setSelectedRange(NSRange(location: isNew ? 0 : (textView.string as NSString).length, length: 0))
            if isNew || textView.window?.firstResponder == nil || textView.window?.firstResponder === textView.window {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NotasTextView else { return }
        if context.coordinator.lastStyle != style {
            context.coordinator.lastStyle = style
            textView.applyStyle(style)
        }
        app.activeEditor = textView
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.saveNow()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let noteID: UUID
        let app: AppState
        weak var textView: NotasTextView?
        var lastStyle: ResolvedStyle?
        private var saveTask: Task<Void, Never>?

        init(noteID: UUID, app: AppState) {
            self.noteID = noteID
            self.app = app
        }

        func scheduleSave() {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
        }

        func saveNow() {
            saveTask?.cancel()
            saveTask = nil
            guard let textView else { return }
            app.store.updateDocument(noteID, textView.document)
        }

        func textDidChange(_ notification: Notification) {
            scheduleSave()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Escape closes whatever overlay is open instead of triggering completion.
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if app.drawer != nil || app.isStylePanelOpen {
                    withAnimation(.snappy(duration: 0.25)) {
                        app.drawer = nil
                        app.isStylePanelOpen = false
                    }
                    return true
                }
            }
            return false
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let string = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            guard let url = URL(string: string.contains("://") ? string : "https://\(string)") else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
