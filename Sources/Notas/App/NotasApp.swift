import AppKit
import SwiftUI
#if canImport(NotasShared)
import NotasShared
#endif

@main
enum Entry {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--assistant-test") || CommandLine.arguments.contains("--check-codex") {
            Task { @MainActor in
                let success = await AssistantSelfTest.run(realCodex: CommandLine.arguments.contains("--check-codex"))
                exit(success ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        #endif
        #if DEBUG || BENCH
        if CommandLine.arguments.contains("--bench") {
            Benchmark.run()
            exit(0)
        }
        #endif
        NotasApp.main()
    }
}

struct NotasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Notas", id: "main") {
            MainView()
                .environment(delegate.app)
                .frame(minWidth: 760, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)
        .commands {
            NotasCommands(app: delegate.app)
            TextEditingCommands()
        }
        MenuBarExtra("Notas", systemImage: "square.and.pencil") {
            Button("Quick note") { delegate.quickCapture?.show() }
            Button("Open Notas") { delegate.showMainWindow() }
            Divider()
            if let capture = delegate.quickCapture {
                Picker("Quick note shortcut", selection: Binding(get: { capture.model.shortcut }, set: { capture.setShortcut($0) })) {
                    ForEach(CaptureShortcut.allCases) { Text($0.label).tag($0) }
                }
            }
            Divider()
            Button("Quit Notas") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: LibraryStore
    let app: AppState
    private var keyMonitor: Any?
    private(set) var quickCapture: QuickCaptureController?
    private var integration: CaptureIntegration?
    private var termSource: DispatchSourceSignal?

    override init() {
        store = LibraryStore()
        store.load()
        app = AppState(store: store)
        app.restoreTabs()
        super.init()
        quickCapture = QuickCaptureController(app: app)
        integration = CaptureIntegration(app: app)
        app.showQuickCapture = { [weak self] in self?.quickCapture?.show() }
        app.selectWidgetNote = { [weak self] in self?.integration?.useCurrentNoteInWidget() }
        app.refreshWidgets = { [weak self] in self?.integration?.publishNow() }
        app.retrySharedCaptures = { [weak self] in self?.integration?.importPending(reportFailures: true) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        integration?.start()
        // A plain `kill` (SIGTERM) quits normally so pending edits get written.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        // ⌘W closes the note tab; only closes the window when no tabs are left.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.quickCapture?.model.shortcut.matches(event) == true {
                self.quickCapture?.toggle()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers == "w", self.quickCapture?.owns(event.window) == true {
                self.quickCapture?.dismiss()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers == "w",
               event.window?.identifier?.rawValue.contains("main") ?? false,
               !self.app.isPaletteOpen {
                return self.app.closeActiveTab() ? nil : event
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.noteAssistant.shutdown()
        app.activeEditor.map { app.store.updateDocument(app.activeNoteID ?? UUID(), $0.document) }
        quickCapture?.model.saveDraft()
        integration?.publishNow()
        store.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        integration?.importPending(reportFailures: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL, url.pathExtension.lowercased() == SharedNoteFile.fileExtension {
                showMainWindow()
                app.openSharedNote(at: url)
                continue
            }
            guard let link = NotasLink(url: url) else { continue }
            switch link {
            case .quickCapture: quickCapture?.show()
            case .note(let id):
                integration?.importPending()
                app.open(id, newTab: true)
                showMainWindow()
            case .open: showMainWindow()
            }
        }
    }

    func showMainWindow() {
        app.showMainWindow?()
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Quick note", action: #selector(openQuickCapture), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func openQuickCapture() { quickCapture?.show() }

    func applicationDidResignActive(_ notification: Notification) {
        if let editor = app.activeEditor, let id = app.activeNoteID {
            store.updateDocument(id, editor.document)
        }
        store.flush()
    }
}

struct NotasCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Quick Note…") { app.showQuickCapture?() }
            Divider()
            Button("New Note") { app.newNote() }.keyboardShortcut("n")
            Button("New Note in Tab") { app.newNote() }.keyboardShortcut("t")
            Button("New Notebook…") { app.toggleDrawer(.all) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { _ = app.closeActiveTab() }
        }

        CommandMenu("Go") {
            Button { app.selectWidgetNote?() } label: {
                if app.activeNoteID != nil && app.activeNoteID == app.widgetNoteID { Label("Shown in Widget", systemImage: "checkmark") }
                else { Text("Show This Note in Widget") }
            }.disabled(app.activeNoteID == nil)
            Divider()
            Button("Search & Commands…") { app.isPaletteOpen = true }.keyboardShortcut("k")
            Button("All Notes") { app.toggleDrawer(.all) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Pinned Notes") { app.toggleDrawer(.pinned) }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { app.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { app.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { app.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandGroup(after: .importExport) {
            Button("Share Note…") { app.shareActiveNote() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(app.activeNoteID == nil)
        }

        CommandMenu("Insert") {
            Button("Photos…") { app.activeEditor?.importPhotos() }
            Button("Scan from iPhone…") { app.activeEditor?.showScanMenu() }
            Divider()
            ForEach([BlockKind.table, .board, .columns, .sketch], id: \.self) { kind in
                Button(kind.displayName) { app.activeEditor?.insertRichBlock(kind) }
            }
            Button("Turn List into Board") { app.activeEditor?.convertListToBoard() }
        }

        CommandMenu("Format") {
            Button("Bold") { app.activeEditor?.toggleMark(.bold) }.keyboardShortcut("b")
            Button("Italic") { app.activeEditor?.toggleMark(.italic) }.keyboardShortcut("i")
            Button("Underline") { app.activeEditor?.toggleMark(.underline) }.keyboardShortcut("u")
            Button("Strikethrough") { app.activeEditor?.toggleMark(.strike) }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { app.activeEditor?.toggleMark(.highlight) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Inline Code") { app.activeEditor?.toggleMark(.code) }.keyboardShortcut("e")
            Divider()
            Button("Heading") { app.activeEditor?.setBlockKind(.heading1) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Subheading") { app.activeEditor?.setBlockKind(.heading2) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Small Heading") { app.activeEditor?.setBlockKind(.heading3) }.keyboardShortcut("3", modifiers: [.command, .option])
            Button("Body") { app.activeEditor?.setBlockKind(.body) }.keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button("Checklist") { app.activeEditor?.setBlockKind(.checklist) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Bulleted List") { app.activeEditor?.setBlockKind(.bullet) }.keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { app.activeEditor?.setBlockKind(.numbered) }.keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Quote") { app.activeEditor?.setBlockKind(.quote) }.keyboardShortcut("'", modifiers: [.command, .shift])
            Button("Callout") { app.activeEditor?.setBlockKind(.callout) }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Code Block") { app.activeEditor?.setBlockKind(.code) }.keyboardShortcut("e", modifiers: [.command, .option])
            Button("Divider") { app.activeEditor?.insertDivider() }.keyboardShortcut("-", modifiers: [.command, .option])
            Divider()
            Button("Mark as Done") { app.activeEditor?.toggleCheckedAtSelection(nil) }.keyboardShortcut(.return, modifiers: .command)
            Button("Indent") { app.activeEditor?.changeIndent(by: 1) }.keyboardShortcut("]")
            Button("Outdent") { app.activeEditor?.changeIndent(by: -1) }.keyboardShortcut("[")
        }

        CommandGroup(after: .toolbar) {
            Button("Chat About This Note") { app.isChatOpen.toggle() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(app.activeNoteID == nil)
            Button("Customize Look") {
                withAnimation(.snappy(duration: 0.25)) { app.isStylePanelOpen.toggle() }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Picker("Appearance", selection: Binding(get: { app.appearance }, set: { app.appearance = $0 })) {
                ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
            }
            Divider()
        }
    }
}
