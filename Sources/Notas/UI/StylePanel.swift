import SwiftUI

/// "Aa": the look of the note in front — theme, accent, fonts, size, spacing, width.
struct StylePanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let style = app.chromeStyle
        let noteStyle = app.activeNote?.style ?? app.defaultStyle

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Theme", style) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                        ForEach(Theme.presets) { theme in
                            ThemeSwatch(theme: theme, isSelected: noteStyle.themeID == theme.id, accent: style.accentColor) {
                                app.updateActiveStyle { $0.themeID = theme.id }
                            }
                        }
                    }
                }

                section("Accent", style) {
                    HStack(spacing: 4) {
                        AccentDot(color: nil, isSelected: noteStyle.accent == nil, style: style) {
                            app.updateActiveStyle { $0.accent = nil }
                        }
                        ForEach(AccentColor.allCases) { accent in
                            AccentDot(color: accent, isSelected: noteStyle.accent == accent, style: style) {
                                app.updateActiveStyle { $0.accent = accent }
                            }
                        }
                    }
                }

                section("Type", style) {
                    VStack(spacing: 0) {
                        row("Title", style) {
                            fontMenu(noteStyle.titleFont, fallback: Theme.preset(id: noteStyle.themeID).titleFont, style: style) { f in
                                app.updateActiveStyle { $0.titleFont = f }
                            }
                        }
                        row("Body", style) {
                            fontMenu(noteStyle.bodyFont, fallback: Theme.preset(id: noteStyle.themeID).bodyFont, style: style) { f in
                                app.updateActiveStyle { $0.bodyFont = f }
                            }
                        }
                        row("Size", style) {
                            HStack(spacing: 2) {
                                stepButton("textformat.size.smaller", style) {
                                    app.updateActiveStyle { $0.textSize = max(12, ($0.textSize ?? 15) - 1) }
                                }
                                Text("\(Int(noteStyle.textSize ?? 15)) pt")
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(style.text)
                                    .frame(width: 42)
                                stepButton("textformat.size.larger", style) {
                                    app.updateActiveStyle { $0.textSize = min(24, ($0.textSize ?? 15) + 1) }
                                }
                            }
                        }
                        row("Spacing", style) {
                            Slider(value: Binding(get: { noteStyle.lineSpacing ?? 1.0 },
                                                  set: { v in app.updateActiveStyle { $0.lineSpacing = v } }),
                                   in: 0.85...1.4)
                                .controlSize(.mini)
                                .tint(style.accentColor)
                                .frame(width: 104)
                        }
                        row("Width", style, last: true) {
                            Picker("", selection: Binding(get: { noteStyle.width ?? .medium },
                                                          set: { w in app.updateActiveStyle { $0.width = w } })) {
                                ForEach(PageWidth.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(width: 150)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    PanelButton(title: "Use for new notes", symbol: "square.and.arrow.down", style: style) {
                        app.defaultStyle = noteStyle
                    }
                    PanelButton(title: "Reset this note", symbol: "arrow.counterclockwise", style: style) {
                        app.updateActiveStyle { $0 = NoteStyle() }
                    }
                }

                Rectangle().fill(style.tertiary.opacity(0.2)).frame(height: 0.5)

                section("App", style) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: Binding(get: { app.appearance }, set: { app.appearance = $0 })) {
                            ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)

                        Text("Default accent")
                            .font(.system(size: 11))
                            .foregroundStyle(style.tertiary)
                        HStack(spacing: 4) {
                            ForEach(AccentColor.allCases) { accent in
                                AccentDot(color: accent, isSelected: app.appAccent == accent, style: style) {
                                    app.appAccent = accent
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .frame(width: 268)
        .background(style.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(style.tertiary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(style.theme.isDark ? 0.45 : 0.12), radius: 26, y: 10)
        .environment(\.colorScheme, style.colorScheme)
    }

    private func section<Content: View>(_ title: String, _ style: ResolvedStyle, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(style.tertiary)
            content()
        }
    }

    private func row<Content: View>(_ label: String, _ style: ResolvedStyle, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(style.secondary)
                Spacer()
                content()
            }
            .frame(height: 34)
            if !last { Rectangle().fill(style.tertiary.opacity(0.15)).frame(height: 0.5) }
        }
    }

    private func fontMenu(_ current: FontChoice?, fallback: FontChoice, style: ResolvedStyle, set: @escaping (FontChoice?) -> Void) -> some View {
        Menu {
            Button("Theme default (\(fallback.label))") { set(nil) }
            Divider()
            ForEach(FontChoice.allCases) { f in
                Button(f.label) { set(f) }
            }
        } label: {
            Text((current ?? fallback).label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(style.text)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func stepButton(_ symbol: String, _ style: ResolvedStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.secondary)
                .frame(width: 24, height: 22)
                .background(style.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if theme.id == Theme.auto.id {
                    HStack(spacing: 0) {
                        Color(hex: Theme.midnight.background)
                        Color(hex: Theme.ink.background)
                    }
                } else {
                    Color(hex: theme.background)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aa")
                        .font(Font(theme.titleFont.nsFont(size: 15, weight: .semibold)))
                    Text(theme.name)
                        .font(.system(size: 9.5, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundStyle(theme.id == Theme.auto.id ? Color.white : Color(hex: theme.text))
                .shadow(color: theme.id == Theme.auto.id ? .black.opacity(0.4) : .clear, radius: 2)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
            }
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct AccentDot: View {
    let color: AccentColor?
    let isSelected: Bool
    let style: ResolvedStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color {
                    Circle().fill(Color(hex: color.hex))
                } else {
                    Circle().strokeBorder(style.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                    Image(systemName: "wand.and.stars").font(.system(size: 8)).foregroundStyle(style.tertiary)
                }
            }
            .frame(width: 15, height: 15)
            .overlay {
                if isSelected { Circle().stroke(style.text, lineWidth: 1.5).frame(width: 20, height: 20) }
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color?.label ?? "Theme default")
    }
}

struct PanelButton: View {
    let title: String
    let symbol: String
    let style: ResolvedStyle
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(style.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(style.background.opacity(hovering ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
