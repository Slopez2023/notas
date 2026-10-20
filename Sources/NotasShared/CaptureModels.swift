import Foundation

public enum CaptureItemDecoder {
    public static func url(from value: NSSecureCoding) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        if let data = value as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}

public struct CaptureAttachment: Codable, Equatable, Sendable {
    public let name: String
    public let typeIdentifier: String
    public init(name: String, typeIdentifier: String) { self.name = name; self.typeIdentifier = typeIdentifier }
}

public struct CaptureRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var links: [URL]
    public var notebookID: UUID?
    public var attachments: [CaptureAttachment]
    public var created: Date

    public init(id: UUID = UUID(), text: String = "", links: [URL] = [], notebookID: UUID? = nil,
                attachments: [CaptureAttachment] = [], created: Date = Date()) {
        self.id = id; self.text = text; self.links = links; self.notebookID = notebookID
        self.attachments = attachments; self.created = created
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && links.isEmpty && attachments.isEmpty }
    public var title: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
            ?? links.first?.host ?? (attachments.isEmpty ? "Quick note" : "Shared photos")
    }
    public var body: String {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        // Keep the full first line in the body when it was shortened for the title.
        if lines[first].trimmingCharacters(in: .whitespaces).count > 160 { return text }
        return lines.dropFirst(first + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

public struct NotebookOption: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public struct WidgetChecklistItem: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    public var checked: Bool
    public init(id: Int, text: String, checked: Bool) { self.id = id; self.text = text; self.checked = checked }
}

public struct WidgetNoteSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var text: String
    public var checklist: [WidgetChecklistItem]
    public var background: UInt32
    public var foreground: UInt32
    public var accent: UInt32
    public var updated: Date
    public init(id: UUID, title: String, text: String, checklist: [WidgetChecklistItem], background: UInt32,
                foreground: UInt32, accent: UInt32, updated: Date) {
        self.id = id; self.title = title; self.text = text; self.checklist = checklist
        self.background = background; self.foreground = foreground; self.accent = accent; self.updated = updated
    }
}

public struct SharedLibrarySnapshot: Codable, Equatable, Sendable {
    public var notebooks: [NotebookOption]
    public var note: WidgetNoteSnapshot?
    public init(notebooks: [NotebookOption] = [], note: WidgetNoteSnapshot? = nil) { self.notebooks = notebooks; self.note = note }
}

public enum NotasLink: Equatable {
    case quickCapture
    case note(UUID)
    case open

    public var url: URL {
        switch self {
        case .quickCapture: URL(string: "notas://quick")!
        case .open: URL(string: "notas://open")!
        case .note(let id): URL(string: "notas://note/\(id.uuidString)")!
        }
    }
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "notas", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        switch url.host?.lowercased() {
        case "quick" where url.path.isEmpty || url.path == "/": self = .quickCapture
        case "open" where url.path.isEmpty || url.path == "/": self = .open
        case "note":
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 1, let id = UUID(uuidString: parts[0]) else { return nil }
            self = .note(id)
        default: return nil
        }
    }
}
