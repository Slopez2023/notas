import AppKit
import SwiftUI

@MainActor
final class NoteSharing {
    weak var anchor: NSView?
    private var sessions: [UUID: Session] = [:]

    func present(_ file: SharedNoteFile, from view: NSView) throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.stephenlopez.notas/SharedCopies", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let active = Set(sessions.keys.map(\.uuidString))
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            if !active.contains(folder.lastPathComponent),
               let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < Date().addingTimeInterval(-7 * 24 * 3600) { try? FileManager.default.removeItem(at: folder) }
        }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let title = file.content.document.title.isEmpty ? "Untitled" : file.content.document.title
            let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
            let name = String(title.components(separatedBy: forbidden).joined(separator: " ").prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = name.isEmpty ? "Note" : name
            let pdf = folder.appendingPathComponent(base + ".pdf")
            let editable = folder.appendingPathComponent(base + "." + SharedNoteFile.fileExtension)
            try file.write(to: editable)
            try NotePDFRenderer(file: file).render().write(to: pdf, options: .atomic)
            let session = Session(items: [pdf, editable], title: title) { [weak self] in self?.sessions[id] = nil }
            sessions[id] = session
            session.show(from: view)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    @MainActor private final class Session: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        let picker: NSSharingServicePicker
        let title: String
        let finish: () -> Void
        private var service: NSSharingService?
        private weak var sourceWindow: NSWindow?

        init(items: [URL], title: String, finish: @escaping () -> Void) {
            picker = NSSharingServicePicker(items: items)
            self.title = title
            self.finish = finish
            super.init()
            picker.delegate = self
        }

        func show(from view: NSView) {
            sourceWindow = view.window
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
            proposedServices.filter { $0.title != "Notas" }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
            sharingService.subject = title
            service = sharingService
            return self
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service == nil { finish() }
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            let alert = NSAlert(error: error)
            if let sourceWindow { alert.beginSheetModal(for: sourceWindow) } else { alert.runModal() }
            finish()
        }
    }
}

extension AppState {
    func shareActiveNote(from anchor: NSView? = nil) {
        guard var note = activeNote, let view = anchor ?? noteSharing.anchor ?? activeEditor, view.window != nil else { return }
        // Take the current document directly, including typing still inside the save debounce.
        if let editor = activeEditor, editor.noteID == note.id { note.document = editor.document }
        do {
            let copy = try SharedNoteFile(note: note, resolved: resolvedStyle(for: note), assets: store.assets(for: note.id), notebook: store.notebook(note.notebookID))
            try noteSharing.present(copy, from: view)
        } catch { showSharingError(error, in: view.window) }
    }

    func openSharedNote(at url: URL) {
        do {
            let copy = try SharedNoteFile.read(from: url)
            let note = try store.importSharedNote(copy)
            open(note.id, newTab: true)
        } catch { showSharingError(error, in: noteSharing.anchor?.window) }
    }

    private func showSharingError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "The note couldn't be shared or opened"
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

struct ShareBarButton: NSViewRepresentable {
    let app: AppState
    let style: ResolvedStyle

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.sendAction(on: .leftMouseDown)
        button.toolTip = "Send a copy with its colors, formatting, and photos (⇧⌘S)"
        button.setAccessibilityLabel("Share note")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = app.activeNoteID != nil
        button.contentTintColor = app.activeNoteID == nil ? style.nsTertiary : style.nsSecondary
        app.noteSharing.anchor = button
    }

    @MainActor final class Coordinator: NSObject {
        let app: AppState
        init(app: AppState) { self.app = app }
        @objc func share(_ sender: NSButton) { app.shareActiveNote(from: sender) }
    }
}
