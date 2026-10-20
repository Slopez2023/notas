import Foundation

/// Data for blocks that aren't text: photos, tables, boards, columns, sketches.
struct BlockPayload: Codable, Equatable {
    /// Asset file names inside the note's `assets/` folder.
    var images: [String]? = nil
    var galleryColumns: Int? = nil
    var table: TableData? = nil
    var board: BoardData? = nil
    /// Plain text for each column of a two-column block.
    var columns: [String]? = nil
    var sketch: SketchData? = nil

    static func empty(for kind: BlockKind) -> BlockPayload {
        switch kind {
        case .gallery: BlockPayload(images: [])
        case .table: BlockPayload(table: TableData(rows: [["", "", ""], ["", "", ""], ["", "", ""]], header: true))
        case .board: BlockPayload(board: BoardData(columns: [
            BoardColumn(title: "To do", cards: []),
            BoardColumn(title: "Doing", cards: []),
            BoardColumn(title: "Done", cards: []),
        ]))
        case .columns: BlockPayload(columns: ["", ""])
        case .sketch: BlockPayload(sketch: SketchData(width: 640, height: 260, strokes: []))
        default: BlockPayload()
        }
    }
}

struct TableData: Codable, Equatable {
    var rows: [[String]]
    var header: Bool = true

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// Makes every row the same length.
    mutating func normalize() {
        let n = max(1, columnCount)
        if rows.isEmpty { rows = [Array(repeating: "", count: n)] }
        for i in rows.indices where rows[i].count < n {
            rows[i] += Array(repeating: "", count: n - rows[i].count)
        }
    }
}

struct BoardData: Codable, Equatable {
    var columns: [BoardColumn]

    mutating func move(card id: String, to columnID: String, before target: String? = nil) {
        guard let source = columns.firstIndex(where: { $0.cards.contains { $0.id == id } }),
              let destination = columns.firstIndex(where: { $0.id == columnID }),
              let index = columns[source].cards.firstIndex(where: { $0.id == id }), id != target else { return }
        let card = columns[source].cards.remove(at: index)
        let insertion = target.flatMap { target in columns[destination].cards.firstIndex { $0.id == target } } ?? columns[destination].cards.count
        columns[destination].cards.insert(card, at: insertion)
    }
}

struct BoardColumn: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var cards: [BoardCard]
}

struct BoardCard: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var text: String
}

struct SketchData: Codable, Equatable {
    /// The canvas size the strokes were drawn at; the sketch scales to fit the page.
    var width: Double
    var height: Double
    var strokes: [SketchStroke]
}

struct SketchStroke: Codable, Equatable {
    enum Tool: String, Codable { case pen, marker }
    var tool: Tool
    /// Nil means the theme's text color.
    var color: UInt32?
    var size: Double
    /// Flattened x, y pairs.
    var points: [Double]
}
