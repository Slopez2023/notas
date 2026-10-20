import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let style = app.chromeStyle
        ZStack(alignment: .topLeading) {
            style.background

            if let id = app.activeNoteID, let note = app.store.notes[id] {
                NoteEditorView(noteID: id, style: app.resolvedStyle(for: note))
                    .id(id)
                    .transition(.opacity)
            } else {
                EmptyStateView()
            }

            TopBar()

            NotebookRail()
                .padding(.leading, 12)
                .frame(maxHeight: .infinity, alignment: .center)

            ZStack(alignment: .topLeading) {
                if let drawer = app.drawer {
                    Color.black.opacity(0.001)
                        .onTapGesture { app.drawer = nil }
                        .transition(.opacity)
                    NotebookDrawer(content: drawer)
                        .padding(.leading, 56)
                        .padding(.top, 46)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(app.drawer != nil)
            .animation(.snappy(duration: 0.25), value: app.drawer)
            .zIndex(1)

            ZStack(alignment: .topTrailing) {
                if app.isStylePanelOpen {
                    StylePanel()
                        .padding(.top, 46)
                        .padding(.trailing, 12)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(app.isStylePanelOpen)
            .animation(.snappy(duration: 0.25), value: app.isStylePanelOpen)
            .zIndex(2)

            if app.isPaletteOpen {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(3)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(style.colorScheme)
        .tint(style.accentColor)
        .animation(.easeInOut(duration: 0.3), value: style)
        .animation(.snappy(duration: 0.2), value: app.isPaletteOpen)
        .alert("A shared note couldn't be imported", isPresented: Binding(get: { app.captureImportError != nil }, set: { if !$0 { app.captureImportError = nil } })) {
            Button("Retry") { DispatchQueue.main.async { app.retrySharedCaptures?() } }
            Button("Later", role: .cancel) { app.captureImportError = nil }
        } message: {
            Text((app.captureImportError ?? "") + " The captured items are still saved in your inbox.")
        }
        .onAppear {
            app.showMainWindow = { openWindow(id: "main") }
        }
        .onChange(of: app.chromeStyle) { app.refreshWidgets?() }
        .onChange(of: app.store.notes.count) { app.pruneTabs() }
        .onChange(of: app.isStylePanelOpen) { _, open in if !open { app.focusEditorSoon() } }
    }
}

struct EmptyStateView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let style = app.chromeStyle
        let recent = Array(app.store.notes(in: nil).prefix(5))
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Notas")
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                    .foregroundStyle(style.text)
                Text("What's on your mind?")
                    .font(.system(size: 14))
                    .foregroundStyle(style.tertiary)
            }
            HStack(spacing: 10) {
                EmptyAction(title: "New note", shortcut: "⌘N", style: style, primary: true) { app.newNote() }
                EmptyAction(title: "Search", shortcut: "⌘K", style: style, primary: false) { app.isPaletteOpen = true }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(style.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    ForEach(recent) { note in
                        Button { app.open(note.id) } label: {
                            HStack {
                                Circle().fill(Color(hex: app.store.notebook(note.notebookID)?.color.hex ?? 0x999999)).frame(width: 6, height: 6)
                                Text(note.displayTitle).font(.system(size: 13)).foregroundStyle(style.secondary).lineLimit(1)
                                Spacer()
                                Text(DrawerRow.shortDate(note.modified)).font(.system(size: 11)).foregroundStyle(style.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyAction: View {
    let title: String
    let shortcut: String
    let style: ResolvedStyle
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(shortcut).font(.system(size: 11.5, design: .rounded)).opacity(0.6)
            }
            .foregroundStyle(primary ? Color(nsColor: contrasting(style.nsAccent)) : style.text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(primary ? style.accentColor.opacity(hovering ? 0.9 : 1) : style.surface.opacity(hovering ? 1 : 0.8),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func contrasting(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.62 ? NSColor(white: 0.08, alpha: 1) : .white
    }
}
