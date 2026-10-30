import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation
import PDFKit

final class ShareViewController: NSViewController {
    private let model = ShareModel()
    private var loaded = false

    override func loadView() {
        preferredContentSize = NSSize(width: 480, height: 400)
        view = NSHostingView(rootView: ShareCaptureView(model: model, save: { [weak self] in self?.save() }, cancel: { [weak self] in
            self?.model.cancel()
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }))
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !loaded, let context = extensionContext else { return }
        loaded = true
        Task { await model.prepare(items: context.inputItems) }
    }
    private func save() {
        do {
            try model.save()
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.stephenlopez.notas.capture-ready"), object: nil, userInfo: nil, deliverImmediately: true)
            extensionContext?.completeRequest(returningItems: nil)
        } catch { model.error = error.localizedDescription }
    }
}

@MainActor @Observable
final class ShareModel {
    var text = ""
    var links: [URL] = []
    var attachments: [CaptureAttachment] = []
    var notebooks: [NotebookOption] = []
    var notebookID: UUID?
    var error: String?
    var notice: String?
    var loading = true
    private var shared: SharedCaptureStore?
    private var staging: URL?
    private let id = UUID()
    private var cancelled = false
    var canSave: Bool {
        !loading && shared != nil && staging != nil && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !links.isEmpty || !attachments.isEmpty)
    }

    func cancel() {
        cancelled = true
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
    }

    func prepare(items: [Any]) async {
        defer { loading = false }
        do {
            let store = try SharedCaptureStore.live()
            shared = store
            let directory = try store.createStagingDirectory(id: id)
            staging = directory
            notebooks = (try? store.snapshot().notebooks) ?? []
            notebookID = notebooks.first?.id
            var texts: [String] = []
            var skipped = 0
            for item in items.compactMap({ $0 as? NSExtensionItem }) {
                for provider in item.attachments ?? [] {
                    if cancelled { throw CocoaError(.userCancelled) }
                    do { try await add(provider, into: directory, texts: &texts) } catch { skipped += 1 }
                }
                if let content = item.attributedContentText?.string, !content.isEmpty, !texts.contains(content) { texts.append(content) }
            }
            text = texts.joined(separator: "\n\n")
            guard !text.isEmpty || !links.isEmpty || !attachments.isEmpty else {
                throw skipped == 0 ? CaptureError.emptyCapture : CaptureError.invalidAttachment
            }
            if skipped > 0 { notice = "\(skipped) item\(skipped == 1 ? "" : "s") couldn't be added" }
        } catch {
            if !cancelled { self.error = error.localizedDescription }
            if let staging { try? FileManager.default.removeItem(at: staging) }
            staging = nil
        }
    }

    func save() throws {
        guard canSave, let shared, let staging else { throw CaptureError.emptyCapture }
        try shared.commit(CaptureRequest(id: id, text: text, links: links, notebookID: notebookID, attachments: attachments), staging: staging)
        self.staging = nil
    }

    private func add(_ provider: NSItemProvider, into directory: URL, texts: inout [String]) async throws {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let value = try await loadItem(provider, type: UTType.fileURL.identifier)
            guard let url = CaptureItemDecoder.url(from: value), url.isFileURL else { throw CaptureError.invalidAttachment }
            attachments.append(try stageFile(url, in: directory))
        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true || UTType($0)?.conforms(to: .pdf) == true }) {
            attachments.append(try await loadFile(provider, type: type, into: directory))
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let value = try await loadItem(provider, type: UTType.url.identifier)
            let url = CaptureItemDecoder.url(from: value)
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw CaptureError.invalidAttachment }
            if !links.contains(url) { links.append(url) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try await loadItem(provider, type: UTType.plainText.identifier)
            guard let string = (value as? String) ?? (value as? Data).flatMap({ String(data: $0, encoding: .utf8) }) else { throw CaptureError.invalidAttachment }
            if !texts.contains(string) { texts.append(string) }
        } else { throw CaptureError.invalidAttachment }
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: error ?? CaptureError.invalidAttachment) }
            }
        }
    }

    private func loadFile(_ provider: NSItemProvider, type: String, into directory: URL) async throws -> CaptureAttachment {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? CaptureError.invalidAttachment }
                    // Copy before the provider's temporary-file access expires.
                    continuation.resume(returning: try stageFile(url, in: directory, typeIdentifier: type))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private func stageFile(_ url: URL, in directory: URL, typeIdentifier: String? = nil) throws -> CaptureAttachment {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let type = typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: url.pathExtension)
    guard let type, type.conforms(to: .image) || type.conforms(to: .pdf) else { throw CaptureError.invalidAttachment }
    let name = UUID().uuidString + "." + (type.preferredFilenameExtension ?? "png")
    let destination = directory.appendingPathComponent(name)
    try FileManager.default.copyItem(at: url, to: destination)
    let valid = type.conforms(to: .pdf)
        ? (PDFDocument(url: destination)?.pageCount ?? 0) > 0
        : NSImage(contentsOf: destination)?.isValid == true
    guard valid else {
        try? FileManager.default.removeItem(at: destination)
        throw CaptureError.invalidAttachment
    }
    return CaptureAttachment(name: name, typeIdentifier: type.identifier)
}

private struct ShareCaptureView: View {
    @Bindable var model: ShareModel
    let save: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "square.and.pencil").foregroundStyle(.tint)
                Text("Save to Notas").font(.headline)
                Spacer()
                Picker("Notebook", selection: $model.notebookID) {
                    Text("Default notebook").tag(Optional<UUID>.none)
                    ForEach(model.notebooks) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 170)
            }
            if model.loading { ProgressView("Preparing your note…").frame(maxWidth: .infinity, minHeight: 150) }
            else {
                TextEditor(text: $model.text).font(.system(size: 14)).frame(minHeight: 130).accessibilityLabel("Shared note text")
                if !model.links.isEmpty { Text(model.links.map(\.absoluteString).joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if !model.attachments.isEmpty { Label("\(model.attachments.count) attached file\(model.attachments.count == 1 ? "" : "s")", systemImage: "photo.on.rectangle").font(.caption).foregroundStyle(.secondary) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save note", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
        }.padding(20).frame(width: 480, height: 400)
            .onChange(of: model.text) { if model.canSave { model.error = nil } }
    }
}
