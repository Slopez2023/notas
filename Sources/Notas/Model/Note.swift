import Foundation

struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var notebookID: UUID
    var tags: [String]
    var created: Date
    var modified: Date
    var pinned: Bool
    var style: NoteStyle
    var document: NoteDocument

    var title: String { document.title }
    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// A one-or-two line preview of the body for lists.
    var preview: String {
        // Stops reading blocks as soon as there are three lines; notes can be long.
        var lines: [String] = []
        for block in document.blocks.dropFirst() {
            for line in block.plainText.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
                if lines.count == 3 { return lines.joined(separator: " ") }
            }
        }
        return lines.joined(separator: " ")
    }

    static func new(in notebookID: UUID) -> Note {
        let now = Date()
        return Note(id: UUID(), notebookID: notebookID, tags: [], created: now, modified: now,
                    pinned: false, style: NoteStyle(), document: .empty)
    }
}

/// Per-note look: a theme preset plus optional overrides.
struct NoteStyle: Codable, Equatable {
    var themeID: String = Theme.auto.id
    var accent: AccentColor? = nil
    var titleFont: FontChoice? = nil
    var bodyFont: FontChoice? = nil
    var textSize: Double? = nil
    var lineSpacing: Double? = nil
    var width: PageWidth? = nil
}

enum PageWidth: String, Codable, CaseIterable, Identifiable {
    case narrow, medium, wide
    var id: String { rawValue }
    var points: CGFloat {
        switch self {
        case .narrow: 600
        case .medium: 720
        case .wide: 900
        }
    }
    var label: String { rawValue.capitalized }
}

struct Notebook: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var color: NotebookColor
    var order: Int
}

enum NotebookColor: String, Codable, CaseIterable, Identifiable {
    case coral, mint, sky, sun, lilac, rose, sage, slate
    var id: String { rawValue }

    var hex: UInt32 {
        switch self {
        case .coral: 0xFF6B57
        case .mint: 0x7FCF9A
        case .sky: 0x6FA8FF
        case .sun: 0xF5C451
        case .lilac: 0xC792EA
        case .rose: 0xFF8FC7
        case .sage: 0x9DB89A
        case .slate: 0x9AA3B5
        }
    }
}
