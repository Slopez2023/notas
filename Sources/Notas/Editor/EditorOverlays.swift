import AppKit
import SwiftUI

/// State shared between the editor and its floating overlays (format bar, "/" menu).
@MainActor
@Observable
final class EditorOverlayModel {
    var style = ResolvedStyle(style: NoteStyle(), systemIsDark: true, appAccent: .violet)

    // Format bar
    var marks: InlineMarks = []
    var blockKind: BlockKind = .body
    var ink: InkColor?
    var highlightColor: InkColor?
    var showColors = false
    var isEditingLink = false
    var linkDraft = ""

    // Slash menu
    var slashQuery = ""
    var slashItems: [SlashItem] = []
    var slashSelection = 0
}

struct SlashItem: Identifiable, Equatable {
    enum Action: Equatable {
        case block(BlockKind)
        case divider
        case scan
    }
    let id: String
    let title: String
    let hint: String
    let symbol: String
    let keywords: [String]
    let action: Action

    static let all: [SlashItem] = [
        SlashItem(id: "photos", title: "Photos", hint: "A gallery of favorite moments", symbol: "photo.on.rectangle", keywords: ["photo", "image", "gallery", "picture"], action: .block(.gallery)),
        SlashItem(id: "scan", title: "Scan from iPhone", hint: "Capture a document or photo", symbol: "doc.viewfinder", keywords: ["scan", "camera", "iphone", "receipt"], action: .scan),
        SlashItem(id: "table", title: "Table", hint: "Budgets, plans and comparisons", symbol: "tablecells", keywords: ["table", "grid", "budget"], action: .block(.table)),
        SlashItem(id: "board", title: "Board", hint: "Arrange cards in columns", symbol: "rectangle.split.3x1", keywords: ["board", "kanban", "cards"], action: .block(.board)),
        SlashItem(id: "columns", title: "Two columns", hint: "Write side by side", symbol: "rectangle.split.2x1", keywords: ["columns", "two", "side"], action: .block(.columns)),
        SlashItem(id: "sketch", title: "Sketch", hint: "Draw with pen or highlighter", symbol: "scribble", keywords: ["sketch", "draw", "doodle"], action: .block(.sketch)),
        SlashItem(id: "body", title: "Text", hint: "Plain writing", symbol: "text.alignleft", keywords: ["text", "body", "paragraph", "plain"], action: .block(.body)),
        SlashItem(id: "h1", title: "Heading", hint: "Big section title", symbol: "textformat.size", keywords: ["heading", "h1", "title"], action: .block(.heading1)),
        SlashItem(id: "h2", title: "Subheading", hint: "Medium title", symbol: "textformat.size.smaller", keywords: ["subheading", "h2"], action: .block(.heading2)),
        SlashItem(id: "h3", title: "Small heading", hint: "Small title", symbol: "textformat.abc", keywords: ["small", "h3"], action: .block(.heading3)),
        SlashItem(id: "check", title: "Checklist", hint: "Things to tick off", symbol: "checklist", keywords: ["checklist", "todo", "task", "check", "box"], action: .block(.checklist)),
        SlashItem(id: "bullet", title: "Bulleted list", hint: "Simple list", symbol: "list.bullet", keywords: ["bullet", "list", "unordered"], action: .block(.bullet)),
        SlashItem(id: "number", title: "Numbered list", hint: "Steps in order", symbol: "list.number", keywords: ["numbered", "ordered", "steps", "list"], action: .block(.numbered)),
        SlashItem(id: "quote", title: "Quote", hint: "Something someone said", symbol: "text.quote", keywords: ["quote", "blockquote"], action: .block(.quote)),
        SlashItem(id: "callout", title: "Callout", hint: "Make it stand out", symbol: "exclamationmark.bubble", keywords: ["callout", "note", "info", "tip", "box"], action: .block(.callout)),
        SlashItem(id: "code", title: "Code", hint: "Monospaced block", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "mono"], action: .block(.code)),
        SlashItem(id: "divider", title: "Divider", hint: "A quiet line", symbol: "minus", keywords: ["divider", "line", "separator", "hr", "rule"], action: .divider),
    ]

    static func matching(_ query: String) -> [SlashItem] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        let prefix = all.filter { item in item.title.lowercased().hasPrefix(q) || item.keywords.contains { $0.hasPrefix(q) } }
        let contains = all.filter { item in !prefix.contains(item) && item.title.lowercased().contains(q) }
        return prefix + contains
    }
}

/// Hosting view that never steals first responder from the editor.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Format bar

struct FormatBar: View {
    let model: EditorOverlayModel
    weak var editor: NotasTextView?
    @FocusState private var linkFocused: Bool

    var body: some View {
        let style = model.style
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                blockMenu(style)
                separator(style)
                markButton(.bold, symbol: "bold", help: "Bold ⌘B", style)
                markButton(.italic, symbol: "italic", help: "Italic ⌘I", style)
                markButton(.underline, symbol: "underline", help: "Underline ⌘U", style)
                markButton(.strike, symbol: "strikethrough", help: "Strikethrough ⇧⌘X", style)
                markButton(.code, symbol: "chevron.left.forwardslash.chevron.right", help: "Inline code ⌘E", style)
                separator(style)
                barButton(symbol: "link", isOn: model.isEditingLink, help: "Link", style) {
                    model.linkDraft = editor?.linkAtSelection ?? ""
                    model.isEditingLink.toggle()
                    model.showColors = false
                    editor?.updateOverlays()
                    if model.isEditingLink { DispatchQueue.main.async { linkFocused = true } }
                }
                colorButton(style)
            }
            .padding(4)

            if model.showColors {
                VStack(alignment: .leading, spacing: 6) {
                    colorRow(title: "Highlight", style) {
                        swatch(nil, filled: false, selected: !model.marks.contains(.highlight), style) { editor?.setHighlight(nil) }
                        swatch(nil, filled: true, selected: model.marks.contains(.highlight) && model.highlightColor == nil, style) { editor?.setHighlight(.accent) }
                        ForEach(InkColor.allCases) { c in
                            swatch(c, filled: true, selected: model.marks.contains(.highlight) && model.highlightColor == c, style) { editor?.setHighlight(.ink(c)) }
                        }
                    }
                    colorRow(title: "Text", style) {
                        swatch(nil, filled: false, selected: model.ink == nil, style) { editor?.setInk(nil) }
                        ForEach(InkColor.allCases) { c in
                            textSwatch(c, selected: model.ink == c, style) { editor?.setInk(c) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 2)
                .transition(.opacity)
            }

            if model.isEditingLink {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(style.tertiary)
                    TextField("Paste or type a link", text: Binding(get: { model.linkDraft }, set: { model.linkDraft = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(style.text)
                        .focused($linkFocused)
                        .onSubmit { commitLink() }
                        .onExitCommand { model.isEditingLink = false; editor?.refocus() }
                    if editor?.linkAtSelection != nil {
                        Button("Remove") { editor?.setLink(nil); model.isEditingLink = false; editor?.refocus() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(style.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .frame(width: 300)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(style.surface.opacity(0.7))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 13))
        .shadow(color: .black.opacity(style.theme.isDark ? 0.4 : 0.14), radius: 14, y: 6)
        .environment(\.colorScheme, style.colorScheme)
        .fixedSize()
    }

    private func commitLink() {
        let url = model.linkDraft.trimmingCharacters(in: .whitespaces)
        editor?.setLink(url.isEmpty ? nil : url)
        model.isEditingLink = false
        editor?.refocus()
    }

    private func blockMenu(_ style: ResolvedStyle) -> some View {
        Menu {
            ForEach([BlockKind.body, .heading1, .heading2, .heading3, .checklist, .bullet, .numbered, .quote, .callout, .code], id: \.self) { kind in
                Button {
                    editor?.setBlockKind(kind, toggle: false)
                } label: {
                    Label(kind.displayName, systemImage: kind.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.blockKind == .title ? "Title" : model.blockKind.displayName)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(style.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.blockKind == .title)
    }

    private func separator(_ style: ResolvedStyle) -> some View {
        Rectangle().fill(style.tertiary.opacity(0.3)).frame(width: 1, height: 16).padding(.horizontal, 3)
    }

    private func markButton(_ mark: InlineMarks, symbol: String, help: String, _ style: ResolvedStyle) -> some View {
        barButton(symbol: symbol, isOn: model.marks.contains(mark), help: help, style) {
            editor?.toggleMark(mark)
        }
    }

    private func barButton(symbol: String, isOn: Bool, help: String, _ style: ResolvedStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? style.accentColor : style.text.opacity(0.85))
                .frame(width: 28, height: 26)
                .background(isOn ? style.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func colorButton(_ style: ResolvedStyle) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { model.showColors.toggle() }
            model.isEditingLink = false
            editor?.updateOverlays()
        } label: {
            ZStack {
                Image(systemName: "highlighter")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.showColors ? style.accentColor : style.text.opacity(0.85))
                Capsule()
                    .fill(model.highlightColor.map { Color(hex: $0.hex) } ?? style.accentColor)
                    .frame(width: 14, height: 2.5)
                    .offset(y: 9)
            }
            .frame(width: 28, height: 26)
            .background(model.showColors ? style.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Highlight & text color")
    }

    private func colorRow<Content: View>(title: String, _ style: ResolvedStyle, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(style.tertiary)
                .frame(width: 58, alignment: .leading)
            content()
        }
    }

    private func swatch(_ color: InkColor?, filled: Bool, selected: Bool, _ style: ResolvedStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if filled {
                    Circle().fill(color.map { Color(hex: $0.hex) } ?? style.accentColor)
                } else {
                    Circle().strokeBorder(style.tertiary, lineWidth: 1.2)
                    Rectangle().fill(style.tertiary).frame(width: 1.2, height: 14).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 16, height: 16)
            .overlay { if selected { Circle().stroke(style.text, lineWidth: 1.5).frame(width: 21, height: 21) } }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color?.label ?? (filled ? "Accent" : "None"))
    }

    private func textSwatch(_ color: InkColor, selected: Bool, _ style: ResolvedStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("A")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: style.theme.isDark ? color.hex : color.deepHex))
                .frame(width: 22, height: 22)
                .overlay { if selected { RoundedRectangle(cornerRadius: 6).stroke(style.text, lineWidth: 1.5) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.label)
    }
}

// MARK: - Slash menu

struct SlashMenu: View {
    let model: EditorOverlayModel
    weak var editor: NotasTextView?
    static let rowHeight: CGFloat = 43

    private func row(_ item: SlashItem, index: Int, style: ResolvedStyle) -> some View {
        let selected = index == model.slashSelection
        return Button {
            editor?.applySlashItem(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? style.accentColor : style.tertiary.mix(with: style.text, by: 0.35))
                    .frame(width: 26, height: 26)
                    .background(style.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(style.text)
                    Text(item.hint).font(.system(size: 11)).foregroundStyle(style.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: Self.rowHeight - 1)
            .background(selected ? style.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.slashSelection = index } }
    }

    var body: some View {
        let style = model.style
        VStack(alignment: .leading, spacing: 1) {
            Text(model.slashQuery.isEmpty ? "INSERT" : "INSERT · \(model.slashQuery.uppercased())")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(style.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 3)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.slashItems.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index, style: style).id(item.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(min(model.slashItems.count, 6)) * Self.rowHeight)
                .onChange(of: model.slashSelection) { _, new in
                    if model.slashItems.indices.contains(new) { proxy.scrollTo(model.slashItems[new].id) }
                }
            }
        }
        .padding(5)
        .frame(width: 250)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(style.surface.opacity(0.75))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(style.theme.isDark ? 0.45 : 0.16), radius: 18, y: 8)
        .environment(\.colorScheme, style.colorScheme)
        .fixedSize()
    }
}
