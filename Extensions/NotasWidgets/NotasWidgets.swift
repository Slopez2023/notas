import SwiftUI
import WidgetKit

private struct NoteEntry: TimelineEntry {
    let date: Date
    let note: WidgetNoteSnapshot?
}

private struct NoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> NoteEntry { NoteEntry(date: .now, note: Self.sample) }
    func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date(timeIntervalSinceNow: 15 * 60))))
    }
    private func current() -> NoteEntry {
        let snapshot = try? SharedCaptureStore.live().snapshot()
        return NoteEntry(date: .now, note: snapshot?.note)
    }
    private static var sample: WidgetNoteSnapshot {
        WidgetNoteSnapshot(id: UUID(), title: "A little plan", text: "Make time for the things you love.",
                           checklist: [WidgetChecklistItem(id: 1, text: "Plan a slow Sunday", checked: true), WidgetChecklistItem(id: 2, text: "Book dinner together", checked: false)],
                           background: 0x17171C, foreground: 0xF5F1E9, accent: 0xA492FF, updated: .now)
    }
}

struct FavoriteNoteWidget: Widget {
    let kind = "NotasFavorite"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteProvider()) { entry in FavoriteNoteView(entry: entry) }
            .configurationDisplayName("Favorite note")
            .description("Keep a note or checklist close. Choose it in Notas under Go → Show This Note in Widget.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct FavoriteNoteView: View {
    let entry: NoteEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int { family == .systemSmall ? 3 : family == .systemMedium ? 4 : 10 }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("NOTAS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
            }.foregroundStyle(Color(rgb: entry.note?.accent ?? 0xA492FF)).widgetAccentable()
            if let note = entry.note {
                Text(note.title).font(.system(.headline, design: .serif)).lineLimit(2)
                if note.checklist.isEmpty {
                    Text(note.text.isEmpty ? "Open in Notas" : note.text).font(.system(size: 12)).lineLimit(family == .systemLarge ? 16 : family == .systemSmall ? 5 : 4)
                        .opacity(0.8)
                } else {
                    ForEach(Array(note.checklist.prefix(limit))) { item in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: item.checked ? "checkmark.circle.fill" : "circle").foregroundStyle(Color(rgb: note.accent))
                            Text(item.text).strikethrough(item.checked).opacity(item.checked ? 0.55 : 1).lineLimit(2)
                        }.font(.system(size: 12))
                    }
                }
            } else {
                Text("Your favorite note").font(.system(.headline, design: .serif))
                Text("Open Notas, choose a note, then Go → Show This Note in Widget.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(rgb: entry.note?.foreground ?? 0xF5F1E9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(Color(rgb: entry.note?.background ?? 0x17171C), for: .widget)
        .widgetURL(entry.note.map { NotasLink.note($0.id).url } ?? NotasLink.open.url)
    }
}

struct QuickCaptureWidget: Widget {
    let kind = "NotasQuickCapture"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteProvider()) { _ in
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "square.and.pencil").font(.system(size: 25, weight: .light)).foregroundStyle(Color(rgb: 0xA492FF)).widgetAccentable()
                Spacer(minLength: 0)
                Text("Quick note").font(.system(.headline, design: .serif))
                Text("What's on your mind?").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .containerBackground(for: .widget) { Color(rgb: 0x17171C) }
                .foregroundStyle(Color(rgb: 0xF5F1E9))
                .widgetURL(NotasLink.quickCapture.url)
        }
        .configurationDisplayName("Quick note")
        .description("Open a small note window from your desktop.")
        .supportedFamilies([.systemSmall])
    }
}

private extension Color {
    init(rgb: UInt32) { self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }
}

@main
struct NotasWidgets: WidgetBundle {
    var body: some Widget { FavoriteNoteWidget(); QuickCaptureWidget() }
}
