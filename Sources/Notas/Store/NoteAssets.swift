import AppKit
import ImageIO
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
        guard let cgImage = Self.cgImage(of: image), let tiff = Self.encode(cgImage, as: .tiff),
              let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { throw AssetError.unreadable }
        return try store(source, longest: max(cgImage.width, cgImage.height))
    }

    private static func cgImage(of image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
    }

    /// Longest side kept for imported photos. Plenty for a note, and a 12 MP original would
    /// otherwise cost tens of megabytes per photo in iCloud.
    static let maxStoredPixels = 3200

    /// Imports an image file without decoding it fully: small JPEG and PNG files are copied as-is,
    /// anything else is downsampled to `maxStoredPixels` and saved as JPEG (PNG when it has transparency).
    private func importImageFile(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw AssetError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        guard longest > 0 else { throw AssetError.unreadable }

        let type = CGImageSourceGetType(source) as String?
        if longest <= Self.maxStoredPixels, let type, let ext = Self.copyableExtensions[type], let data = try? Data(contentsOf: url) {
            return try write(data, extension: ext)
        }
        return try store(source, longest: longest)
    }

    /// Shared by file and pasted images: downsample to `maxStoredPixels`, then JPEG unless the image has alpha.
    private func store(_ source: CGImageSource, longest: Int) throws -> String {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, Self.maxStoredPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AssetError.unreadable }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let data = Self.encode(image, as: hasAlpha ? .png : .jpeg) else { throw AssetError.unreadable }
        return try write(data, extension: hasAlpha ? "png" : "jpg")
    }

    private static let copyableExtensions: [String: String] = [UTType.jpeg.identifier: "jpg", UTType.png.identifier: "png"]

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
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
        return [try importImageFile(url)]
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
            let ext = (name as NSString).pathExtension
            names[name] = try destination.write(data, extension: ext.isEmpty ? "png" : ext)
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


/// Decoded, downsampled photos for the editor. A gallery redraws often (typing, resizing,
/// scrolling), and decoding a full-size photo each time made every redraw take a fifth of a second.
enum PhotoCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(url.path)@\(maxPixel)" as NSString }

    static func cached(_ url: URL, maxPixel: Int) -> NSImage? { cache.object(forKey: key(url, maxPixel)) }

    /// Decodes off the main thread. Returns nil when the file is missing or still downloading from iCloud.
    static func load(_ url: URL, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        let image = await Task.detached(priority: .userInitiated) { thumbnail(url, maxPixel: maxPixel) }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key(url, maxPixel), cost: cost)
        }
        return image
    }

    /// Retries a photo that isn't on disk yet. iCloud files download on demand, so a failed iCloud
    /// read requests the download and tries again on a backoff.
    static func loadWhenAvailable(_ url: URL, maxPixel: Int, backoff: [Double] = [1, 3, 10],
                                  isUbiquitous: (URL) -> Bool = PhotoCache.isICloudItem) async -> NSImage? {
        var waits = backoff[...]
        while true {
            if let image = await load(url, maxPixel: maxPixel) { return image }
            guard !Task.isCancelled, isUbiquitous(url), let wait = waits.popFirst() else { return nil }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return nil }
        }
    }

    static func isICloudItem(_ url: URL) -> Bool {
        FileManager.default.isUbiquitousItem(at: url) || url.path.contains("/Mobile Documents/")
    }

    nonisolated private static func thumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
