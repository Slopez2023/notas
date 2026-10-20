#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum UIStabilityTests {
    static func run() async -> Bool {
        _ = NSApplication.shared
        let accessibilityFlags = ["AXEnhancedUserInterface", "AXManualAccessibility"].map { NSAccessibility.Attribute(rawValue: $0) }
        let oldAccessibility = accessibilityFlags.map { NSApp.accessibilityAttributeValue($0) }
        for flag in accessibilityFlags { NSApp.accessibilitySetValue(true, forAttribute: flag) }
        defer {
            for (flag, value) in zip(accessibilityFlags, oldAccessibility) { NSApp.accessibilitySetValue(value ?? false, forAttribute: flag) }
        }
        let argumentDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var isolatedArguments = argumentDefaults
        isolatedArguments["AppleInterfaceStyle"] = "Light"
        UserDefaults.standard.setVolatileDomain(isolatedArguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(argumentDefaults, forName: UserDefaults.argumentDomain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notas-ui-\(UUID())")
        let defaults = MemoryDefaults()
        let store = LibraryStore(rootURL: root)
        let app = AppState(store: store, preferences: defaults)
        defer {
            let _: Bool = store.flush()
            try? FileManager.default.removeItem(at: root)
        }
        var failures = 0
        func check(_ result: Bool, _ label: String) {
            print("\(result ? "PASS" : "FAIL") UI \(label)")
            if !result { failures += 1 }
        }

        let palette = Host(CommandPalette().environment(app), width: 760, height: 500)
        let capture = Host(TextField("Capture", text: .constant("")), width: 300, height: 200)
        await settle()
        func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
        app.isPaletteOpen = true
        key(53, [], in: capture.window)
        check(app.isPaletteOpen, "palette leaves another window's Escape alone")
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .shift, .control, [.command, .shift]] {
            app.isPaletteOpen = true
            key(36, modifiers, in: palette.window)
            check(app.isPaletteOpen, "palette leaves modified Return alone: \(modifiers.rawValue)")
        }
        app.isPaletteOpen = true
        key(36, [], in: capture.window)
        check(app.isPaletteOpen, "palette leaves another window's Return alone")
        app.isPaletteOpen = true
        key(53, [], in: palette.window)
        check(!app.isPaletteOpen, "palette consumes its own plain Escape")
        palette.close()
        capture.close()
        await settle()

        for index in 0..<25 { _ = store.createNotebook(name: "Notebook \(index)", color: .mint) }
        let rail = Host(NotebookRail().environment(app), width: 220, height: 440)
        await settle()
        check(scrollViews(rail.view).contains { $0.hasVerticalScroller }, "rail has vertical overflow navigation in a real host")
        if let scroll = scrollViews(rail.view).first, let document = scroll.documentView {
            let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle()
            check(scroll.contentView.bounds.minY > 0, "notebook rail scrolls to the final notebook")
            let newButton = element("notebook-new", in: rail.view)
            check(newButton.map { contains(rail.view.accessibilityFrame(), $0.accessibilityFrame()) } == true,
                  "New notebook stays visible below the overflowing rail")
        }
        app.notebookEditTarget = .new
        await settle()
        let creationElements = NSApp.windows.flatMap { elements($0) }
        let nameField = creationElements.first { $0.accessibilityIdentifier() == "notebook-create-name" }
        let confirm = creationElements.first { $0.accessibilityIdentifier() == "notebook-create-confirm" }
        check(nameField != nil && confirm != nil, "creation state presents name and Create controls")
        if let nameField, let confirm {
            let before = store.notebooks.count
            check(!confirm.isAccessibilityEnabled(), "empty notebook names cannot be created")
            let field = (nameField.object as? NSCell)?.controlView as? NSTextField
            if let field, field.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                editor.insertText("  Created by UI test  ", replacementRange: editor.selectedRange())
            }
            await settle()
            let updatedConfirm = NSApp.windows.flatMap { elements($0) }.first { $0.accessibilityIdentifier() == "notebook-create-confirm" }
            check(updatedConfirm?.accessibilityPerformPress() == true, "Create accepts the entered name")
            await settle()
            let created = store.notebooks.first { $0.name == "Created by UI test" }
            check(store.notebooks.count == before + 1 && created != nil, "creation adds exactly one trimmed notebook")
            check(app.notebookEditTarget == nil && created.map { app.drawer == .notebook($0.id) } == true,
                  "creation dismisses the editor and opens the new notebook")
        }
        app.notebookEditTarget = nil
        rail.close()

        for index in 0..<12 {
            let note = store.createNote(in: store.notebooks.first?.id)
            store.updateDocument(note.id, NoteDocument(blocks: [Block(kind: .title, runs: [InlineRun(text: "Tab \(index)")])]))
            app.open(note.id, newTab: true)
        }
        let tabs = Host(TabStrip(style: app.chromeStyle).environment(app), width: 240, height: 34)
        await settle()
        check(scrollViews(tabs.view).contains { $0.hasHorizontalScroller }, "tabs have horizontal overflow navigation in a real host")
        if let first = app.tabs.first, let last = app.tabs.last, let scroll = scrollViews(tabs.view).first {
            app.activate(first)
            await settle()
            check(scroll.contentView.bounds.minX < 1, "activating the first tab reveals it")
            app.activate(last)
            await settle()
            let lastTab = element("note-tab-\(last.uuidString)", in: tabs.view)
            check(scroll.contentView.bounds.minX > 0 && lastTab.map { contains(scroll.accessibilityFrame(), $0.accessibilityFrame()) } == true,
                  "activating the last tab reveals it")
        }
        tabs.close()

        let longName = String(repeating: "W", count: 200)
        if let notebook = store.notebooks.first, let id = app.activeNoteID {
            store.renameNotebook(notebook.id, to: longName)
            store.move(id, to: notebook.id)
            let header = Host(NoteHeader(noteID: id).environment(app), width: 340, height: 32)
            await settle()
            let label = element("note-header-notebook", in: header.view)
            print("UI notebook label frame \(String(describing: label?.accessibilityFrame()))")
            check(label.map { contains(header.view.accessibilityFrame(), $0.accessibilityFrame()) } == true,
                  "200-character notebook label stays within a 340-point header")
            header.close()
        }

        for id in app.tabs { app.close(id) }
        let main = Host(MainView().environment(app), width: 760, height: 500)
        await settle()
        check(app.windowWidth == 760, "first layout initializes windowWidth to 760")
        app.isChatOpen = true
        await settle()
        for width: CGFloat in [760, 640] {
            main.window.setContentSize(NSSize(width: width, height: 500))
            main.view.layoutSubtreeIfNeeded()
            app.isPaletteOpen = true
            await settle()
            let search = element("note-command-search", in: main.view)
            let searchFrame = search?.accessibilityFrame() ?? .zero
            let point = NSPoint(x: searchFrame.maxX - 12, y: searchFrame.midY)
            // hitTest expects the superview's coordinates. The content view's superview uses window coordinates.
            let windowPoint = main.window.convertPoint(fromScreen: point)
            let hitView = main.view.hitTest(windowPoint)
            let hitTextField = sequence(first: hitView, next: { $0?.superview }).contains { $0 is NSTextField }
            check(searchFrame.width > 0 && hitTextField, "palette search receives hits above chat at width \(Int(width))")
            app.isPaletteOpen = false
            await settle()
        }
        main.window.setContentSize(NSSize(width: 760, height: 500))
        main.view.layoutSubtreeIfNeeded()
        await settle()
        NSCursor.crosshair.push()
        app.isChatOpen = false
        await settle()
        try? await Task.sleep(for: .milliseconds(400))
        check(NSCursor.current === NSCursor.crosshair, "removing an unhovered resize handle preserves the cursor stack")
        if NSCursor.current === NSCursor.crosshair { NSCursor.pop() }
        main.close()
        await settle()
        print("UI stability failures: \(failures)")
        return failures == 0
    }

    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private var values: [String: Any] = [:]
        override func object(forKey key: String) -> Any? { values[key] }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        override func data(forKey key: String) -> Data? { values[key] as? Data }
    }

    @MainActor
    private final class Host<V: View> {
        let window: NSWindow
        let view: NSHostingView<V>
        init(_ content: V, width: CGFloat, height: CGFloat) {
            view = NSHostingView(rootView: content)
            view.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderBack(nil)
            view.layoutSubtreeIfNeeded()
        }
        func close() { window.contentView = nil; window.close() }
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    private struct Accessible {
        let object: AnyObject
        func accessibilityIdentifier() -> String? { object.accessibilityIdentifier?() ?? nil }
        func accessibilityLabel() -> String? { object.accessibilityLabel?() ?? nil }
        func accessibilityValue() -> Any? { object.accessibilityValue?() ?? nil }
        func accessibilityFrame() -> NSRect { object.accessibilityFrame?() ?? .zero }
        func isAccessibilityEnabled() -> Bool { object.isAccessibilityEnabled?() ?? false }
        func accessibilityPerformPress() -> Bool { object.accessibilityPerformPress?() ?? false }
    }

    private static func elements(_ node: Any, depth: Int = 0) -> [Accessible] {
        guard depth < 30 else { return [] }
        let object = node as AnyObject
        return [Accessible(object: object)] + (object.accessibilityChildren?() ?? []).flatMap { elements($0, depth: depth + 1) }
    }

    private static func element(_ id: String, in view: NSView) -> Accessible? {
        elements(view).first { $0.accessibilityIdentifier() == id }
    }

    private static func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        inner.width > 0 && inner.height > 0 && outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    private static func nativeViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(nativeViews) }

    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

}
#endif
