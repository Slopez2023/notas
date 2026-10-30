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
        case .cannotReplaceApp: "Notas can only update itself when it is named Notas.app and sits in a writable folder such as Applications. Move Notas into the Applications folder (or rename it to Notas.app, or reinstall with the install command), then try again."
        case .processFailed(let message): message
        }
    }
}

/// Runs a tool off the main actor. stderr is drained while the process runs, so a large message cannot block it.
private func runTool(_ executable: String, arguments: [String]) async throws {
    try await Task.detached {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.processFailed(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The update could not be prepared.")
        }
    }.value
}

@MainActor
@Observable
final class UpdateController {
    private(set) var isBusy = false
    private(set) var activityTitle = "Check for Updates…"
    /// A newer release found by the quiet background check, shown as an Update button.
    private(set) var availableVersion: UpdateVersion?
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
    /// Helper arguments staged by a quit-for-update. Launched only once quitting is certain.
    private var pendingInstall: (arguments: [String], work: URL)?

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return !UserDefaults.standard.bool(forKey: Self.manualOnlyKey) }
        set {
            withMutation(keyPath: \.checksAutomatically) { UserDefaults.standard.set(!newValue, forKey: Self.manualOnlyKey) }
            if newValue { checkQuietly() }
        }
    }

    private static let releaseURL = URL(string: "https://api.github.com/repos/Slopez2023/notas/releases/latest")!
    private static let assetName = "Notas.app.zip"
    private static let bundleIdentifier = "com.stephenlopez.notas"
    private static let maximumDownloadSize: Int64 = 500 * 1_024 * 1_024
    private static let lastCheckedKey = "updates.lastChecked"
    private static let manualOnlyKey = "updates.manualOnly"
    private static let quietInterval: TimeInterval = 6 * 60 * 60
    private var quietTimer: Timer?

    var versionDescription: String {
        let version = currentVersion?.description ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    /// Checks at launch and every few hours without interrupting; a newer release only
    /// lights up the Update button, it never installs on its own.
    func startQuietChecks() {
        checkQuietly()
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkQuietly() }
        }
    }

    private func checkQuietly() {
        guard checksAutomatically, !isBusy else { return }
        Task {
            guard let release = try? await latestRelease(),
                  let current = currentVersion,
                  let latest = UpdateVersion(release.tagName) else { return }
            markChecked()
            availableVersion = latest > current ? latest : nil
        }
    }

    private func markChecked() {
        lastChecked = .now
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
    }

    func checkForUpdates() {
        guard !isBusy else { return }
        isBusy = true
        activityTitle = "Checking for Updates…"

        Task {
            defer {
                if pendingInstall == nil {
                    isBusy = false
                    activityTitle = "Check for Updates…"
                }
            }
            do {
                let release = try await latestRelease()
                markChecked()
                guard let current = currentVersion else { throw UpdateError.invalidCurrentVersion }
                guard let latest = UpdateVersion(release.tagName) else { throw UpdateError.invalidRelease }
                guard latest > current else {
                    availableVersion = nil
                    showUpToDate(version: current)
                    return
                }
                availableVersion = latest

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
        try await runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])

        let candidate = extracted.appendingPathComponent("Notas.app", isDirectory: true)
        guard let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == Self.bundleIdentifier,
              let candidateVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateVersion(candidateVersionString) == version else {
            throw UpdateError.invalidArchive
        }
        try await runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", candidate.path])

        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        guard Self.canReplace(destination),
              Bundle.main.bundleIdentifier == Self.bundleIdentifier,
              fileManager.isWritableFile(atPath: parent.path),
              let helper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
            throw UpdateError.cannotReplaceApp
        }

        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".Notas-update-\(token).app", isDirectory: true)
        let backup = parent.appendingPathComponent(".Notas-backup-\(token).app", isDirectory: true)
        let arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), candidate.path, destination.path, staged.path, backup.path, work.path]
        handedOffToInstaller = true
        pendingInstall = (arguments, work)
        activityTitle = "Installing Update…"
        NSApp.terminate(nil)
    }

    /// Starts the helper once quitting is certain (called from applicationWillTerminate).
    func launchPendingInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = pending.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: pending.work)
        }
    }

    /// Called when quitting was cancelled (for example, a note could not be saved) after an update was staged.
    func cancelPendingInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        try? FileManager.default.removeItem(at: pending.work)
        isBusy = false
        activityTitle = "Check for Updates…"
        let alert = NSAlert()
        alert.messageText = "The update was not installed"
        alert.informativeText = "Notas stayed open, so the update was cancelled. It will be offered again the next time you check."
        alert.runModal()
    }

    /// The helper only swaps a bundle named Notas.app.
    static func canReplace(_ url: URL) -> Bool {
        url.lastPathComponent == "Notas.app"
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
