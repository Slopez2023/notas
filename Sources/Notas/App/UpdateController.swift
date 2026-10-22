import AppKit
import Foundation
import Observation

struct UpdateVersion: Comparable, CustomStringConvertible, Equatable {
    private let components: [Int]

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parsed = normalized.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !parsed.isEmpty, parsed.count == normalized.split(separator: ".", omittingEmptySubsequences: false).count else { return nil }
        components = parsed
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func == (lhs: Self, rhs: Self) -> Bool {
        compare(lhs, rhs) == 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ lhs: Self, _ rhs: Self) -> Int {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private enum UpdateError: LocalizedError {
    case invalidCurrentVersion
    case invalidRelease
    case missingDownload
    case invalidResponse
    case downloadTooLarge
    case invalidArchive
    case cannotReplaceApp
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: "This copy of Notas does not have a valid version number."
        case .invalidRelease: "The latest release has an invalid version number."
        case .missingDownload: "The latest release does not include Notas.app.zip."
        case .invalidResponse: "GitHub returned an unexpected response."
        case .downloadTooLarge: "The update download is unexpectedly large."
        case .invalidArchive: "The downloaded update is not a valid Notas app."
        case .cannotReplaceApp: "Notas cannot replace this app from its current folder."
        case .processFailed(let message): message
        }
    }
}

@MainActor
@Observable
final class UpdateController {
    private(set) var isBusy = false
    private(set) var activityTitle = "Check for Updates…"

    private static let releaseURL = URL(string: "https://api.github.com/repos/Slopez2023/notas/releases/latest")!
    private static let assetName = "Notas.app.zip"
    private static let bundleIdentifier = "com.stephenlopez.notas"
    private static let maximumDownloadSize: Int64 = 500 * 1_024 * 1_024

    func checkForUpdates() {
        guard !isBusy else { return }
        isBusy = true
        activityTitle = "Checking for Updates…"

        Task {
            defer {
                isBusy = false
                activityTitle = "Check for Updates…"
            }
            do {
                let release = try await latestRelease()
                guard let current = currentVersion else { throw UpdateError.invalidCurrentVersion }
                guard let latest = UpdateVersion(release.tagName) else { throw UpdateError.invalidRelease }
                guard latest > current else {
                    showUpToDate(version: current)
                    return
                }

                let response = showAvailable(current: current, latest: latest)
                if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(release.htmlURL)
                    return
                }
                guard response == .alertFirstButtonReturn else { return }

                activityTitle = "Downloading Update…"
                try await downloadAndInstall(release: release, version: latest)
            } catch {
                showError(error)
            }
        }
    }

    private var currentVersion: UpdateVersion? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return UpdateVersion(value)
    }

    private func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notas/\(currentVersion?.description ?? "unknown")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.invalidResponse }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadAndInstall(release: GitHubRelease, version: UpdateVersion) async throws {
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
              asset.browserDownloadURL.scheme == "https",
              asset.browserDownloadURL.host == "github.com" else {
            throw UpdateError.missingDownload
        }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("Notas/\(currentVersion?.description ?? "unknown")", forHTTPHeaderField: "User-Agent")
        let (temporaryDownload, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.invalidResponse }
        if response.expectedContentLength > Self.maximumDownloadSize { throw UpdateError.downloadTooLarge }

        let fileManager = FileManager.default
        let downloadAttributes = try fileManager.attributesOfItem(atPath: temporaryDownload.path)
        guard let size = downloadAttributes[.size] as? NSNumber else { throw UpdateError.invalidResponse }
        if size.int64Value > Self.maximumDownloadSize {
            throw UpdateError.downloadTooLarge
        }
        let work = fileManager.temporaryDirectory.appendingPathComponent("Notas-update-\(UUID().uuidString)", isDirectory: true)
        var handedOffToInstaller = false
        defer {
            if !handedOffToInstaller { try? fileManager.removeItem(at: work) }
        }
        let archive = work.appendingPathComponent(Self.assetName)
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try fileManager.moveItem(at: temporaryDownload, to: archive)
        try run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])

        let candidate = extracted.appendingPathComponent("Notas.app", isDirectory: true)
        guard let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == Self.bundleIdentifier,
              let candidateVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateVersion(candidateVersionString) == version else {
            throw UpdateError.invalidArchive
        }
        try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", candidate.path])

        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app",
              Bundle.main.bundleIdentifier == Self.bundleIdentifier,
              fileManager.isWritableFile(atPath: parent.path),
              let helper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
            throw UpdateError.cannotReplaceApp
        }

        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".Notas-update-\(token).app", isDirectory: true)
        let backup = parent.appendingPathComponent(".Notas-backup-\(token).app", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), candidate.path, destination.path, staged.path, backup.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        handedOffToInstaller = true
        NSApp.terminate(nil)
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.processFailed(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The update could not be prepared.")
        }
    }

    private func showAvailable(current: UpdateVersion, latest: UpdateVersion) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Notas \(latest) is available"
        alert.informativeText = "You are using Notas \(current). The update will download, install, and reopen Notas."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    private func showUpToDate(version: UpdateVersion) {
        let alert = NSAlert()
        alert.messageText = "Notas is up to date"
        alert.informativeText = "You are using the latest release, version \(version)."
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Notas could not update"
        alert.runModal()
    }
}
