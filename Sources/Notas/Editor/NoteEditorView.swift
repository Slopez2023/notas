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

        let header = NSHostingView(rootView: NoteHeader(noteID: noteID).environment(app))
        header.sizingOptions = []
        textView.headerView = header

        textView.applyStyle(style)
        context.coordinator.lastStyle = style
        context.coordinator.mount(textView)

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
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let noteID: UUID
        weak var app: AppState?
        weak var textView: NotasTextView?
        var lastStyle: ResolvedStyle?
        private var mountToken: UUID?
        private var origin: DocumentOrigin?
        private var saveTask: Task<Void, Never>?
        private var dirty = false
        private var invalidated = false
        private var retainedSnapshot: EditorSnapshot?

        init(noteID: UUID, app: AppState) {
            self.noteID = noteID
            self.app = app
        }

        func mount(_ textView: NotasTextView) {
            self.textView = textView
            textView.noteID = noteID
            textView.delegate = self
            textView.onUserEdit = { [weak self] in self?.scheduleSave() }
            guard let app else { return }
            textView.noteAssets = app.store.assets(for: noteID)
            if let opened = try? app.store.editableDocument(for: noteID) {
                origin = opened.origin
                textView.load(opened.document)
            }
            mountToken = app.registerEditor(self)
            app.activeEditor = textView
        }

        func dismantle() {
            if let token = mountToken, app?.isCurrentEditorRegistration(noteID: noteID, token: token) == true {
                _ = checkpoint()
            }
            detach()
        }

        private func detach() {
            saveTask?.cancel()
            saveTask = nil
            if let token = mountToken {
                app?.unregisterEditor(noteID: noteID, token: token)
                mountToken = nil
            }
        }

        func invalidate() {
            invalidated = true
            dirty = false
            saveTask?.cancel()
            saveTask = nil
        }

        func scheduleSave() {
            guard !invalidated else { return }
            dirty = true
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
            guard !invalidated else { return }
            guard let token = mountToken, app?.isCurrentEditorRegistration(noteID: noteID, token: token) == true else { return }
            _ = checkpoint()
        }

        /// Flushes normalization and transfers one immutable snapshot. A failed transfer keeps the snapshot.
        @discardableResult
        func checkpoint() -> Bool {
            guard !invalidated else { return true }
            guard let app else { return !dirty }
            textView?.flushRestyle()
            finishMarkedText()
            let document: NoteDocument?
            if let textView {
                document = textView.document
            } else if let retainedSnapshot {
                document = retainedSnapshot.document
            } else {
                document = nil
            }
            guard let document else { return !dirty }
            let basis = origin ?? (try? app.store.editableDocument(for: noteID))?.origin
            guard let basis else { return !dirty }
            let snapshot = EditorSnapshot(origin: basis, document: document)
            do {
                origin = try app.store.accept(snapshot)
                retainedSnapshot = nil
                dirty = false
                saveTask?.cancel()
                saveTask = nil
                return true
            } catch {
                retainedSnapshot = snapshot
                return false
            }
        }

        private func finishMarkedText() {
            guard let textView, textView.hasMarkedText() else { return }
            let marked = textView.markedRange()
            guard marked.location != NSNotFound,
                  let fragment = textView.attributedSubstring(forProposedRange: marked, actualRange: nil) else { return }
            textView.insertText(fragment.string, replacementRange: marked)
        }

        func textDidChange(_ notification: Notification) {
            scheduleSave()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Escape closes whatever overlay is open instead of triggering completion.
            guard let app else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if app.drawer != nil || app.isStylePanelOpen || app.isChatFloating {
                    withAnimation(.snappy(duration: 0.25)) {
                        app.drawer = nil
                        app.isStylePanelOpen = false
                        app.isChatOpen = false
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
