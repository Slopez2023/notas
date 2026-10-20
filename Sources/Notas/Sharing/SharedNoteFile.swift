import AppKit

/// A portable copy has no library identity. Opening it always creates an independent note.
struct SharedNoteFile: Codable {
    static let fileExtension = "notasnote"
    static let typeIdentifier = "com.stephenlopez.notas.note"
    private let format: String
    private let version: Int
    let style: NoteStyle
    let tags: [String]
    let created: Date
    let modified: Date
    let pinned: Bool
    let notebookName: String?
    let notebookColor: NotebookColor?
    var content: BlockClipboard

    init(note: Note, resolved: ResolvedStyle, assets: NoteAssets, notebook: Notebook?) throws {
        format = Self.typeIdentifier
        version = 1
        style = NoteStyle(themeID: resolved.theme.id, accent: resolved.accent,
                          titleFont: resolved.titleFont, bodyFont: resolved.bodyFont,
                          textSize: Double(resolved.textSize), lineSpacing: Double(resolved.lineSpacing), width: resolved.width)
        tags = note.tags
        created = note.created
        modified = note.modified
        pinned = note.pinned
        notebookName = notebook?.name
        notebookColor = notebook?.color
        content = try BlockClipboard(document: note.document, source: assets)
    }

    @MainActor static func read(from url: URL) throws -> SharedNoteFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200_000_000 else { throw ShareError.tooLarge }
        var file = try LibraryStore.decoder.decode(Self.self, from: Data(contentsOf: url))
        file.content.document = file.content.document.normalizingExternalIndentation()
        guard file.format == typeIdentifier, file.version == 1 else { throw ShareError.unsupported }
        guard Theme.presets.contains(where: { $0.id == file.style.themeID && $0.id != "auto" }),
              file.style.accent != nil, file.style.titleFont != nil, file.style.bodyFont != nil,
              let size = file.style.textSize, (8...48).contains(size),
              let spacing = file.style.lineSpacing, (0.5...3).contains(spacing), file.style.width != nil,
              file.content.document.blocks.first?.kind == .title else { throw ShareError.invalid }
        let names = Set(file.content.document.blocks.flatMap { $0.payload?.images ?? [] })
        guard Set(file.content.assets.keys) == names else { throw ShareError.invalid }
        for name in names {
            guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.contains("\\"), name != ".", name != "..",
                  let data = file.content.assets[name], NSImage(data: data) != nil else { throw ShareError.invalid }
        }
        for block in file.content.document.blocks {
            if let sketch = block.payload?.sketch {
                guard sketch.width.isFinite, sketch.height.isFinite, sketch.width > 0, sketch.height > 0,
                      sketch.strokes.allSatisfy({ $0.size.isFinite && $0.size > 0 && $0.points.count.isMultiple(of: 2) && $0.points.allSatisfy(\.isFinite) }) else { throw ShareError.invalid }
            }
        }
        return file
    }

    @MainActor func write(to url: URL) throws {
        let data = try LibraryStore.encoder.encode(self)
        guard data.count <= 200_000_000 else { throw ShareError.tooLarge }
        try data.write(to: url, options: .atomic)
    }

    enum ShareError: LocalizedError {
        case unsupported, invalid, tooLarge, rendering
        var errorDescription: String? {
            switch self {
            case .unsupported: "This note uses a file format this version of Notas can't open."
            case .invalid: "This shared note is incomplete or damaged. Ask the sender to share it again."
            case .tooLarge: "This note is too large to share. Share fewer photos at a time."
            case .rendering: "The note's PDF could not be created. Please try again."
            }
        }
    }
}
