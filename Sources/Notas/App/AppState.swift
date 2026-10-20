import AppKit
import Observation
import SwiftUI

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum DrawerContent: Equatable {
    case all
    case pinned
    case notebook(UUID)
    case tag(String)
}

/// UI state for the window: open tabs, which panels are showing, and app-wide preferences.
@MainActor
@Observable
final class AppState {
    let store: LibraryStore

    private(set) var tabs: [UUID] = []
    private(set) var activeNoteID: UUID?
    var drawer: DrawerContent?
    var isPaletteOpen = false
    var isStylePanelOpen = false
    var captureImportError: String?

    var appearance: AppearanceSetting {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance"); refreshWidgets?() }
    }
    var appAccent: AccentColor {
        didSet { defaults.set(appAccent.rawValue, forKey: "accent"); refreshWidgets?() }
    }
    /// Style new notes start with.
    var defaultStyle: NoteStyle {
        didSet { if let data = try? JSONEncoder().encode(defaultStyle) { defaults.set(data, forKey: "defaultStyle") } }
    }
    var widgetNoteID: UUID? {
        didSet { defaults.set(widgetNoteID?.uuidString, forKey: "widgetNoteID") }
    }
    private(set) var systemIsDark: Bool { didSet { refreshWidgets?() } }

    /// The editor currently on screen, for menu commands.
    @ObservationIgnored var showMainWindow: (() -> Void)?
    @ObservationIgnored var showQuickCapture: (() -> Void)?
    @ObservationIgnored var selectWidgetNote: (() -> Void)?
    @ObservationIgnored var refreshWidgets: (() -> Void)?
    @ObservationIgnored var retrySharedCaptures: (() -> Void)?
    @ObservationIgnored weak var activeEditor: NotasTextView?
    @ObservationIgnored let noteSharing = NoteSharing()
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    init(store: LibraryStore, preferences: UserDefaults? = nil) {
        self.store = store
        defaults = preferences ?? ProcessInfo.processInfo.environment["NOTAS_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        widgetNoteID = defaults.string(forKey: "widgetNoteID").flatMap(UUID.init(uuidString:))
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        appAccent = AccentColor(rawValue: defaults.string(forKey: "accent") ?? "") ?? .violet
        if let data = defaults.data(forKey: "defaultStyle"), let style = try? JSONDecoder().decode(NoteStyle.self, from: data) {
            defaultStyle = style
        } else {
            defaultStyle = NoteStyle()
        }
        systemIsDark = Self.readSystemIsDark()

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsDark = Self.readSystemIsDark() }
        }
    }

    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    var effectiveDark: Bool {
        switch appearance {
        case .system: systemIsDark
        case .dark: true
        case .light: false
        }
    }

    // MARK: Style

    var activeNote: Note? { activeNoteID.flatMap { store.notes[$0] } }

    func resolvedStyle(for note: Note?) -> ResolvedStyle {
        ResolvedStyle(style: note?.style ?? defaultStyle, systemIsDark: effectiveDark, appAccent: appAccent)
    }

    /// Style for the window chrome: follows whichever note is in front.
    var chromeStyle: ResolvedStyle { resolvedStyle(for: activeNote) }

    func updateActiveStyle(_ change: (inout NoteStyle) -> Void) {
        guard let id = activeNoteID else { return }
        store.mutate(id, touch: false) { change(&$0.style) }
    }

    // MARK: Tabs

    func restoreTabs() {
        let saved = (defaults.stringArray(forKey: "tabs") ?? []).compactMap(UUID.init(uuidString:))
        tabs = saved.filter { store.notes[$0] != nil }
        let active = defaults.string(forKey: "activeTab").flatMap(UUID.init(uuidString:))
        activeNoteID = active.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
        if tabs.isEmpty, let first = store.pinnedNotes.first ?? store.notes(in: nil).first {
            open(first.id)
        }
    }

    private func persistTabs() {
        defaults.set(tabs.map(\.uuidString), forKey: "tabs")
        defaults.set(activeNoteID?.uuidString, forKey: "activeTab")
    }

    /// Show a note. Replaces the current tab unless `newTab` (or nothing is open).
    func open(_ id: UUID, newTab: Bool = false) {
        guard store.notes[id] != nil else { return }
        if tabs.contains(id) {
            activate(id)
        } else if newTab || activeNoteID == nil {
            let at = activeNoteID.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.endIndex
            tabs.insert(id, at: at)
            activate(id)
        } else if let current = activeNoteID, let i = tabs.firstIndex(of: current) {
            let previous = tabs[i]
            tabs[i] = id
            activate(id)
            store.discardIfEmpty(previous)
        }
        persistTabs()
    }

    func activate(_ id: UUID) {
        guard activeNoteID != id else { return }
        activeNoteID = id
        persistTabs()
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: i)
        if activeNoteID == id {
            activeNoteID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
        }
        store.discardIfEmpty(id)
        persistTabs()
    }

    func closeActiveTab() -> Bool {
        guard let id = activeNoteID else { return false }
        close(id)
        return true
    }

    func cycleTab(_ offset: Int) {
        guard let id = activeNoteID, let i = tabs.firstIndex(of: id), tabs.count > 1 else { return }
        activate(tabs[(i + offset + tabs.count) % tabs.count])
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { activate(tabs[index]) }
    }

    func reorderTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: from)
        tabs.insert(id, at: tabs.firstIndex(of: target) ?? tabs.endIndex)
        persistTabs()
    }

    /// Drops tabs whose notes no longer exist (e.g. deleted from the drawer).
    func pruneTabs() {
        let before = tabs
        tabs = tabs.filter { store.notes[$0] != nil }
        if let id = activeNoteID, store.notes[id] == nil {
            activeNoteID = tabs.first
        }
        if before != tabs { persistTabs() }
    }

    // MARK: Actions

    /// The notebook new notes go into: the open drawer's, else the current note's.
    var contextNotebookID: UUID? {
        if case .notebook(let id) = drawer { return id }
        return activeNote?.notebookID ?? store.sortedNotebooks.first?.id
    }

    func newNote(in notebookID: UUID? = nil, newTab: Bool = true) {
        let note = store.createNote(in: notebookID ?? contextNotebookID, style: defaultStyle)
        open(note.id, newTab: newTab)
        drawer = nil
        isPaletteOpen = false
        focusEditorSoon()
    }

    func delete(_ id: UUID) {
        store.trash(id)
        if let i = tabs.firstIndex(of: id) {
            tabs.remove(at: i)
            if activeNoteID == id { activeNoteID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)] }
            persistTabs()
        }
    }

    func toggleDrawer(_ content: DrawerContent) {
        withAnimation(.snappy(duration: 0.28)) {
            drawer = drawer == content ? nil : content
        }
    }

    func focusEditorSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let editor = self?.activeEditor else { return }
            editor.window?.makeFirstResponder(editor)
        }
    }
}
