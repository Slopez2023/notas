import AppKit
import SwiftUI
#if canImport(NotasShared)
import NotasShared
#endif

@MainActor
@Observable
final class QuickCaptureModel {
    var text = ""
    var notebookID: UUID?
    var error: String?
    var shortcut: CaptureShortcut = .optionSpace
    var shortcutError: String?
    var draftID = UUID()
    let app: AppState
    let draftURL: URL
    private var draftTask: Task<Void, Never>?

    init(app: AppState, draftURL: URL) {
        self.app = app; self.draftURL = draftURL
        if let draft = try? QuickCaptureDraft.read(from: draftURL), app.store.notes[draft.id] == nil {
            text = draft.text; notebookID = draft.notebookID; draftID = draft.id
        }
        if let raw = app.defaults.string(forKey: "captureShortcut"), let saved = CaptureShortcut(rawValue: raw) { shortcut = saved }
    }

    func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    func saveDraft() {
        draftTask?.cancel(); draftTask = nil
        do { try QuickCaptureDraft(id: draftID, text: text, notebookID: notebookID).write(to: draftURL) }
        catch { self.error = "Your draft could not be saved. " + error.localizedDescription }
    }

    @discardableResult
    func save() throws -> Note {
        let request = CaptureRequest(id: draftID, text: text, notebookID: notebookID)
        let note = try app.store.importCapture(request, style: app.defaultStyle)
        text = ""; draftID = UUID(); error = nil
        saveDraft()
        return note
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onDismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    let model: QuickCaptureModel
    private let hotKey = GlobalCaptureHotKey()
    private var panel: CapturePanel?
    private var previousApp: NSRunningApplication?

    init(app: AppState, draftURL: URL? = nil) {
        let root: URL
        if ProcessInfo.processInfo.environment["NOTAS_LIBRARY"] != nil {
            root = app.store.rootURL.appendingPathComponent("Drafts", isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Notas/Drafts", isDirectory: true)
        }
        model = QuickCaptureModel(app: app, draftURL: draftURL ?? root.appendingPathComponent("quick-capture.json"))
        super.init()
        hotKey.action = { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        registerShortcut()
    }

    func setShortcut(_ value: CaptureShortcut) {
        model.shortcut = value
        model.app.defaults.set(value.rawValue, forKey: "captureShortcut")
        registerShortcut()
    }

    private func registerShortcut() {
        let status = hotKey.register(model.shortcut)
        model.shortcutError = status == noErr ? nil : "\(model.shortcut.label) is unavailable. Choose another shortcut in the Notas menu."
    }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    func toggle() {
        if panel?.isVisible == true { dismiss() } else { show() }
    }

    func show() {
        if panel == nil {
            let panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 366),
                                     styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Quick note"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.onDismiss = { [weak self] in self?.dismiss() }
            panel.contentView = NSHostingView(rootView: QuickCaptureView(model: model, save: { [weak self] open in self?.save(open: open) }, dismiss: { [weak self] in self?.dismiss() }))
            self.panel = panel
        }
        guard let panel else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        if model.notebookID == nil || model.app.store.notebook(model.notebookID!) == nil { model.notebookID = model.app.contextNotebookID }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2 + 75))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        model.saveDraft()
        panel?.orderOut(nil)
    }

    func save(open: Bool) {
        do {
            let note = try model.save()
            panel?.orderOut(nil)
            if open {
                model.app.open(note.id, newTab: true)
                model.app.showMainWindow?()
                NSApp.activate()
            } else if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp.activate()
            }
        } catch { model.error = error.localizedDescription }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
}

private struct QuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    let save: (Bool) -> Void
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let style = model.app.resolvedStyle(for: nil)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(style.accentColor)
                Text("Quick note").font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker("Notebook", selection: $model.notebookID) {
                    ForEach(model.app.store.sortedNotebooks) { notebook in Text(notebook.name).tag(Optional(notebook.id)) }
                }.labelsHidden().frame(maxWidth: 160)
            }
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("What's on your mind?").foregroundStyle(style.tertiary).padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: $model.text).font(.system(size: 15)).scrollContentBackground(.hidden)
                    .focused($focused).accessibilityLabel("Quick note text")
            }.frame(minHeight: 180)
            if let error = model.error ?? model.shortcutError { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                Text("Esc keeps your draft").font(.system(size: 11)).foregroundStyle(style.tertiary)
                Spacer()
                Button("Save & open") { save(true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Save note") { save(false) }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
            }.disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(22).padding(.top, 14)
        .background(style.background).foregroundStyle(style.text).tint(style.accentColor)
        .environment(\.colorScheme, style.colorScheme)
        .onAppear { focused = true }
        .onChange(of: model.text) { model.scheduleDraftSave() }
        .onChange(of: model.notebookID) { model.scheduleDraftSave() }
        .onExitCommand { dismiss() }
    }
}
