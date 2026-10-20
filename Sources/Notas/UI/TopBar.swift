import SwiftUI

/// Tabs in the middle, look + command buttons on the right. Doubles as the window's drag area.
struct TopBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let style = app.chromeStyle
        HStack(spacing: 0) {
            // Traffic lights and balance for the trailing actions. This shrinks with the
            // window so a narrow window never overflows the row it sits in.
            Color.clear.frame(minWidth: 78, maxWidth: 160)
            Spacer(minLength: 6)
            TabStrip(style: style)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                BarButton(label: "Chat", help: "Chat about this note (⌥⌘J)", isOn: app.isChatOpen, style: style) {
                    withAnimation(.snappy(duration: 0.25)) { app.isChatOpen.toggle() }
                }
                ShareBarButton(app: app, style: style)
                    .frame(width: 66, height: 26)
                BarButton(label: "Aa", help: "Customize this note's look (⌥⌘L)", isOn: app.isStylePanelOpen, style: style) {
                    withAnimation(.snappy(duration: 0.25)) { app.isStylePanelOpen.toggle() }
                }
                BarButton(label: "⌘K", help: "Search and commands", isOn: app.isPaletteOpen, style: style) {
                    app.isPaletteOpen = true
                }
            }
            .frame(maxWidth: 210, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .frame(height: 34)
        .background {
            LinearGradient(stops: [.init(color: style.background, location: 0),
                                   .init(color: style.background, location: 0.65),
                                   .init(color: style.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
}

struct BarButton: View {
    let label: String
    let help: String
    var isOn = false
    let style: ResolvedStyle
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isOn ? style.text : style.tertiary.mix(with: style.text, by: hovering ? 0.5 : 0.25))
                .frame(minWidth: 26, minHeight: 24)
                .padding(.horizontal, 6)
                .background(isOn ? style.accentColor.opacity(0.22) : style.surface.opacity(hovering ? 1 : 0.7),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct TabStrip: View {
    let style: ResolvedStyle
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 3) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(app.tabs, id: \.self) { id in
                            if let note = app.store.notes[id] {
                                TabItem(note: note, isActive: id == app.activeNoteID, style: style)
                                    .id(id)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: app.activeNoteID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: app.tabs) {
                    if let id = app.activeNoteID { proxy.scrollTo(id) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                    if let id = app.activeNoteID { proxy.scrollTo(id) }
                }
            }
            Button {
                app.newNote()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note (⌘N)")
        }
        .animation(.snappy(duration: 0.22), value: app.tabs)
    }
}

struct TabItem: View {
    let note: Note
    let isActive: Bool
    let style: ResolvedStyle
    @Environment(AppState.self) private var app
    @State private var hovering = false

    var body: some View {
        let notebook = app.store.notebook(note.notebookID)
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: notebook?.color.hex ?? 0x999999))
                .frame(width: 6, height: 6)
                .opacity(isActive ? 1 : 0.7)
            Text(note.displayTitle)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(style.text.opacity(isActive ? 1 : 0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 44, maxWidth: 150, alignment: .leading)
            ZStack {
                if hovering || isActive && app.tabs.count > 1 {
                    Button { app.close(note.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(style.tertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                }
            }
            .frame(width: 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 26)
        .background(isActive ? style.surface : (hovering ? style.surface.opacity(0.5) : .clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityIdentifier("note-tab-\(note.id.uuidString)")
        .onTapGesture { app.activate(note.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close Tab") { app.close(note.id) }
            Button("Close Other Tabs") { for id in app.tabs where id != note.id { app.close(id) } }
            Divider()
            Button(note.pinned ? "Unpin" : "Pin") { app.store.togglePin(note.id) }
        }
    }
}
