import Foundation

/// The semantic content of a note. Stores *what* the text is (a heading, a checked
/// item, bold words), never *how* it looks — fonts and colors come from the theme.
struct NoteDocument: Codable, Equatable {
    var blocks: [Block]

    static let empty = NoteDocument(blocks: [Block(kind: .title, runs: [])])

    /// First block's text, used as the note's title everywhere.
    var title: String {
        blocks.first?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Everything after the title, flattened for previews and search.
    var bodyText: String {
        blocks.dropFirst().map(\.plainText).joined(separator: "\n")
    }

    var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    var isEmpty: Bool {
        !blocks.contains { $0.kind.isAttachment || !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var wordCount: Int {
        plainText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

enum BlockKind: String, Codable, CaseIterable {
    case title
    case body
    case heading1
    case heading2
    case heading3
    case bullet
    case numbered
    case checklist
    case quote
    case callout
    case code
    case divider
    case gallery
    case table
    case board
    case columns
    case sketch

    var isList: Bool { self == .bullet || self == .numbered || self == .checklist }

    /// Blocks drawn by a live view (one attachment character in the text).
    var isAttachment: Bool { self == .gallery || self == .table || self == .board || self == .columns || self == .sketch }

    /// Blocks you can't type inside of: dividers and attachment blocks.
    var isObject: Bool { isAttachment || self == .divider }

    /// Kinds a new paragraph keeps when you press Return. Quotes and callouts end on Return
    /// (⇧↩ adds a line inside them); code handles Return itself.
    var continuesOnReturn: Bool { isList }

    var displayName: String {
        switch self {
        case .title: "Title"
        case .body: "Text"
        case .heading1: "Heading"
        case .heading2: "Subheading"
        case .heading3: "Small heading"
        case .bullet: "Bulleted list"
        case .numbered: "Numbered list"
        case .checklist: "Checklist"
        case .quote: "Quote"
        case .callout: "Callout"
        case .code: "Code"
        case .divider: "Divider"
        case .gallery: "Photos"
        case .table: "Table"
        case .board: "Board"
        case .columns: "Two columns"
        case .sketch: "Sketch"
        }
    }

    var symbol: String {
        switch self {
        case .title: "textformat.size.larger"
        case .body: "text.alignleft"
        case .heading1: "textformat.size"
        case .heading2: "textformat.size.smaller"
        case .heading3: "textformat.abc"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .checklist: "checklist"
        case .quote: "text.quote"
        case .callout: "exclamationmark.bubble"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .divider: "minus"
        case .gallery: "photo.on.rectangle"
        case .table: "tablecells"
        case .board: "rectangle.split.3x1"
        case .columns: "rectangle.split.2x1"
        case .sketch: "scribble"
        }
    }
}

struct Block: Codable, Equatable {
    var kind: BlockKind
    var checked: Bool? = nil
    var indent: Int? = nil
    var runs: [InlineRun]
    var payload: BlockPayload? = nil

    /// Text for search and previews; includes the words inside tables, boards and columns.
    var plainText: String {
        guard let payload else { return runs.map(\.text).joined() }
        var parts: [String] = []
        if let t = payload.table { parts += t.rows.map { $0.joined(separator: " ") } }
        if let b = payload.board { parts += b.columns.map { ([$0.title] + $0.cards.map(\.text)).joined(separator: " ") } }
        if let c = payload.columns { parts += c }
        return parts.joined(separator: "\n")
    }
}

struct InlineMarks: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let bold = InlineMarks(rawValue: 1 << 0)
    static let italic = InlineMarks(rawValue: 1 << 1)
    static let underline = InlineMarks(rawValue: 1 << 2)
    static let strike = InlineMarks(rawValue: 1 << 3)
    static let code = InlineMarks(rawValue: 1 << 4)
    static let highlight = InlineMarks(rawValue: 1 << 5)
}

/// Named colors for highlighter and text ink. Rendered per theme so they stay readable.
enum InkColor: String, Codable, CaseIterable, Identifiable {
    case yellow, orange, red, pink, purple, blue, green
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Bright swatch, also used for highlights.
    var hex: UInt32 {
        switch self {
        case .yellow: 0xF7D154
        case .orange: 0xF5A35C
        case .red: 0xF27B6B
        case .pink: 0xF28DC7
        case .purple: 0xA78BFA
        case .blue: 0x6CB6F5
        case .green: 0x7ED6A0
        }
    }

    /// Deeper version for text on light backgrounds.
    var deepHex: UInt32 {
        switch self {
        case .yellow: 0xA87B06
        case .orange: 0xC2610F
        case .red: 0xC8372D
        case .pink: 0xBE3E88
        case .purple: 0x6E46D6
        case .blue: 0x1F6FC0
        case .green: 0x23884F
        }
    }
}

struct InlineRun: Codable, Equatable {
    var text: String
    var marks: InlineMarks = []
    var link: String? = nil
    /// Highlighter color when `marks` contains `.highlight`; nil means the note's accent.
    var highlightColor: InkColor? = nil
    /// Text color; nil means the theme's.
    var ink: InkColor? = nil

    private enum CodingKeys: String, CodingKey { case text, marks, link, highlightColor, ink }

    init(text: String, marks: InlineMarks = [], link: String? = nil, highlightColor: InkColor? = nil, ink: InkColor? = nil) {
        self.text = text
        self.marks = marks
        self.link = link
        self.highlightColor = highlightColor
        self.ink = ink
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        marks = try c.decodeIfPresent(InlineMarks.self, forKey: .marks) ?? []
        link = try c.decodeIfPresent(String.self, forKey: .link)
        highlightColor = try c.decodeIfPresent(InkColor.self, forKey: .highlightColor)
        ink = try c.decodeIfPresent(InkColor.self, forKey: .ink)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if !marks.isEmpty { try c.encode(marks, forKey: .marks) }
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(highlightColor, forKey: .highlightColor)
        try c.encodeIfPresent(ink, forKey: .ink)
    }
}
