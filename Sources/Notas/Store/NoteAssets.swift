import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Files belong to the note package. Retain unused files so undo can restore deleted photos.
struct NoteAssets {
    let directory: URL

    init(package: URL) { directory = package.appendingPathComponent("assets", isDirectory: true) }

    func url(for name: String) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              name != ".", name != "..", !name.contains("\\") else { return nil }
        return directory.appendingPathComponent(name)
    }

    func write(_ data: Data, extension ext: String = "png") throws -> String {
        let name = UUID().uuidString + "." + ext
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    func importImage(_ image: NSImage) throws -> String {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw AssetError.unreadable }
        return try write(data)
    }

    func importFile(_ url: URL) throws -> [String] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw AssetError.unreadable }
            return try (0..<pdf.pageCount).map { index in
                guard let page = pdf.page(at: index) else { throw AssetError.unreadable }
                let rect = page.bounds(for: .mediaBox)
                let scale = min(2, 2000 / max(rect.width, rect.height, 1))
                return try importImage(page.thumbnail(of: NSSize(width: rect.width * scale, height: rect.height * scale), for: .mediaBox))
            }
        }
        guard let image = NSImage(contentsOf: url) else { throw AssetError.unreadable }
        return [try importImage(image)]
    }

    enum AssetError: LocalizedError {
        case unreadable, missing
        var errorDescription: String? {
            switch self {
            case .unreadable: "This file could not be read as an image or PDF."
            case .missing: "A photo could not be found. Wait for iCloud to download it and try again."
            }
        }
    }
}

struct BlockClipboard: Codable {
    var document: NoteDocument
    var assets: [String: Data]

    init(document: NoteDocument, source: NoteAssets?) throws {
        self.document = document
        assets = [:]
        for name in Set(document.blocks.flatMap { $0.payload?.images ?? [] }) {
            guard let url = source?.url(for: name), let data = try? Data(contentsOf: url) else { throw NoteAssets.AssetError.missing }
            assets[name] = data
        }
    }

    func imported(into destination: NoteAssets?) throws -> NoteDocument {
        var result = document
        var names: [String: String] = [:]
        for (name, data) in assets {
            guard let destination, NSImage(data: data) != nil else { throw NoteAssets.AssetError.unreadable }
            names[name] = try destination.write(data)
        }
        for index in result.blocks.indices {
            if let images = result.blocks[index].payload?.images {
                result.blocks[index].payload?.images = try images.map {
                    guard let name = names[$0] else { throw NoteAssets.AssetError.missing }
                    return name
                }
            }
        }
        return result
    }
}
