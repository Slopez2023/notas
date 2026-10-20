import Foundation

public enum CaptureError: LocalizedError {
    case sharedContainerUnavailable, invalidAttachment, emptyCapture
    public var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable: "Sharing is unavailable in this build of Notas."
        case .invalidAttachment: "A shared file could not be read. Nothing has been imported."
        case .emptyCapture: "Write something or add a link or photo first."
        }
    }
}

/// The extension publishes complete packages; only the main app consumes them.
public struct SharedCaptureStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func live(bundle: Bundle = .main) throws -> SharedCaptureStore {
        guard let group = bundle.object(forInfoDictionaryKey: "NotasAppGroupIdentifier") as? String,
              !group.isEmpty, !group.hasPrefix("."), !group.contains("$("),
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CaptureError.sharedContainerUnavailable
        }
        return SharedCaptureStore(directory: url)
    }

    public var inboxURL: URL { directory.appendingPathComponent("Captures", isDirectory: true) }
    public var snapshotURL: URL { directory.appendingPathComponent("widget-library.json") }

    public func createStagingDirectory(id: UUID) throws -> URL {
        let url = directory.appendingPathComponent("Staging", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func attachmentURL(name: String, in package: URL) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name != ".", name != "..",
              !name.contains("\\") else { throw CaptureError.invalidAttachment }
        return package.appendingPathComponent(name)
    }

    public func commit(_ request: CaptureRequest, staging: URL) throws {
        guard !request.isEmpty else { throw CaptureError.emptyCapture }
        let destination = inboxURL.appendingPathComponent(request.id.uuidString + ".capture", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try self.request(in: destination) == request else { throw CaptureError.invalidAttachment }
            return
        }
        for attachment in request.attachments {
            let url = try Self.attachmentURL(name: attachment.name, in: staging)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.invalidAttachment }
        }
        let data = try JSONEncoder().encode(request)
        try data.write(to: staging.appendingPathComponent("capture.json"), options: .atomic)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    public func pendingPackages() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: inboxURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "capture" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func request(in package: URL) throws -> CaptureRequest {
        guard package.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL else { throw CaptureError.invalidAttachment }
        let request = try JSONDecoder().decode(CaptureRequest.self, from: Data(contentsOf: package.appendingPathComponent("capture.json")))
        guard package.deletingPathExtension().lastPathComponent.uppercased() == request.id.uuidString else { throw CaptureError.invalidAttachment }
        return request
    }

    public func acknowledge(package: URL) throws {
        guard package.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL,
              package.pathExtension == "capture" else { throw CaptureError.invalidAttachment }
        try FileManager.default.removeItem(at: package)
    }

    public func publish(_ snapshot: SharedLibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        if (try? Data(contentsOf: snapshotURL)) != data { try data.write(to: snapshotURL, options: .atomic) }
    }

    public func snapshot() throws -> SharedLibrarySnapshot {
        try JSONDecoder().decode(SharedLibrarySnapshot.self, from: Data(contentsOf: snapshotURL))
    }
}

public struct QuickCaptureDraft: Codable, Equatable {
    public var id: UUID
    public var text: String
    public var notebookID: UUID?
    public init(id: UUID = UUID(), text: String = "", notebookID: UUID? = nil) {
        self.id = id; self.text = text; self.notebookID = notebookID
    }
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    public static func read(from url: URL) throws -> QuickCaptureDraft {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
