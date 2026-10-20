import Foundation

enum AssistantProvider: String, Codable {
    case chatgpt, opencode

    var model: String { self == .chatgpt ? "gpt-6.1-sol" : "gpt-6-luna" }
    var modelName: String { self == .chatgpt ? "Sol" : "Luna" }
    var serviceName: String { self == .chatgpt ? "OpenAI" : "OpenCode" }
    static let opencodeURL = "https://opencode.ai/inference/go/openai/v1"
    static let keyVariable = "OPENCODE_API_KEY"
}

@MainActor
final class CodexConnection {
    let provider: AssistantProvider
    var model: String { provider.model }
    /// Delivered only to the child's environment. Never logged, never put on the command line.
    var apiKey: String?
    var baseURL = AssistantProvider.opencodeURL
    var onEvent: ((String, [String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    private var initialized = false
    private let home: URL
    let scratch: URL
    var executable: URL?

    init(home: URL, provider: AssistantProvider = .chatgpt, apiKey: String? = nil) {
        self.home = home
        self.provider = provider
        self.apiKey = apiKey
        scratch = home.deletingLastPathComponent().appendingPathComponent("Scratch", isDirectory: true)
    }

    static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    static let disabledFeatures = ["shell_tool", "apps", "plugins", "remote_plugin", "hooks", "memories", "multi_agent",
                                   "multi_agent_v2", "browser_use", "computer_use", "view_image", "image_generation",
                                   "code_mode", "code_mode_host", "skill_search", "sleep_tool"]

    static var policyOverrides: [String] {
        disabledFeatures.map { "features.\($0)=false" } + [
            "features.skip_host_skill_discovery=true", "web_search=\"disabled\"", "project_doc_max_bytes=0",
            "shell_environment_policy.inherit=\"none\"", "cli_auth_credentials_store=\"keyring\"",
            "approval_policy=\"never\"", "default_permissions=\"notas\"", "model_reasoning_effort=\"medium\""
        ]
    }

    var providerOverrides: [String] {
        guard provider == .opencode else { return [] }
        let session = UUID().uuidString.lowercased()
        return ["model_provider=\"opencode\"",
                "model_providers.opencode={name=\"OpenCode Go\", base_url=\"\(baseURL)\", env_key=\"\(AssistantProvider.keyVariable)\", " +
                "wire_api=\"responses\", requires_openai_auth=false, supports_websockets=false, " +
                "http_headers={\"x-opencode-session\"=\"\(session)\"}}",
                "model=\"\(model)\""]
    }

    var permissionOverrides: [String] {
        let path = scratch.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["permissions.notas.filesystem={\":minimal\"=\"read\", \"\(path)\"=\"read\"}",
                "permissions.notas.network.enabled=false"]
    }

    func start() async throws {
        if initialized { return }
        guard process == nil else { throw AssistantError.message("Codex is still connecting. Try again shortly.") }
        guard let binary = executable ?? Self.findExecutable() else {
            throw AssistantError.message("Install Codex CLI, or choose its executable in Chat settings.")
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let proc = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.executableURL = binary
        proc.arguments = ["app-server", "--listen", "stdio://"] + (Self.policyOverrides + providerOverrides + permissionOverrides).flatMap { ["-c", $0] }
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "TMPDIR", "LANG", "PATH", "SHELL"] { env[key] = ProcessInfo.processInfo.environment[key] }
        env["CODEX_HOME"] = home.path
        if provider == .opencode {
            guard let apiKey, !apiKey.isEmpty else { throw AssistantError.message("Add your OpenCode API key first.") }
            env[AssistantProvider.keyVariable] = apiKey
        }
        proc.environment = env
        proc.currentDirectoryURL = scratch
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; diagnostics = stderr.fileHandleForReading
        buffer.removeAll(keepingCapacity: false)
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                if data.isEmpty { self.stop(reason: "Codex disconnected. Reconnect to resume the conversation.") }
                else { self.receive(data) }
            }
        }
        // Drain stderr without logging account data, prompt text, or credentials.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        proc.terminationHandler = { [weak self, weak proc] _ in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.stop(reason: "Codex stopped. Reconnect to resume the conversation.")
            }
        }
        process = proc
        do {
            try proc.run()
            let hello = try await request("initialize", ["clientInfo": ["name": "notas", "title": "Notas", "version": "1.0"],
                                                       "capabilities": ["experimentalApi": true]])
            guard let agent = hello["userAgent"] as? String, agent.contains("/0.163.") else {
                throw AssistantError.message("This build of Notas requires Codex CLI 0.163.x. Choose a compatible binary in Chat settings.")
            }
            try notify("initialized", [:])
            try await verifyIsolation()
            initialized = true
        } catch {
            stop(reason: "Codex couldn't connect. Check the selected executable and version.")
            throw error
        }
    }

    private func verifyIsolation() async throws {
        let denied = home.appendingPathComponent("isolation-check.txt")
        try Data("notas-private-sentinel".utf8).write(to: denied, options: .atomic)
        defer { try? FileManager.default.removeItem(at: denied) }
        let common: [String: Any] = ["cwd": scratch.path, "permissionProfile": "notas", "timeoutMs": 3000]
        var control = common
        control["command"] = ["/bin/echo", "notas-sandbox-ok"]
        let allowed = try await request("command/exec", control)
        guard allowed["exitCode"] as? Int == 0,
              (allowed["stdout"] as? String)?.contains("notas-sandbox-ok") == true else {
            throw AssistantError.message("Codex's note isolation policy couldn't be verified on this Mac.")
        }
        var check = common
        check["command"] = ["/bin/cat", denied.path]
        let blocked = try await request("command/exec", check)
        guard let code = blocked["exitCode"] as? Int, code != 0,
              !(blocked["stdout"] as? String ?? "").contains("notas-private-sentinel") else {
            throw AssistantError.message("Codex did not enforce note isolation. Chat has been disabled.")
        }
    }

    func stop(reason: String = "Codex disconnected.") {
        let proc = process
        process = nil; initialized = false
        output?.readabilityHandler = nil; diagnostics?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? diagnostics?.close()
        input = nil; output = nil; diagnostics = nil; buffer.removeAll()
        if let proc, proc.isRunning {
            proc.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        let requests = pending
        pending.removeAll()
        for item in requests.values {
            item.timeout.cancel()
            item.continuation.resume(throwing: AssistantError.message(reason))
        }
        if proc != nil { onDisconnect?(reason) }
    }

    func request(_ method: String, _ params: [String: Any], timeout: Double = 30) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw AssistantError.message("Connect to Codex first.") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let self, let item = self.pending.removeValue(forKey: id) else { return }
                item.continuation.resume(throwing: AssistantError.message("Codex didn't acknowledge \(method). Reconnect before sending again."))
                self.stop(reason: "Connection timed out. Reconnect to reconcile the conversation.")
            }
            pending[id] = Pending(continuation: continuation, timeout: timer)
            do { try write(["id": id, "method": method, "params": params]) }
            catch {
                pending.removeValue(forKey: id)?.timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) throws {
        try write(["method": method, "params": params])
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw AssistantError.message("Codex is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 8_000_000 else { stop(reason: "Codex sent an oversized response."); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                stop(reason: "Codex sent an invalid protocol response."); return
            }
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let id = message["id"] {
                    // No server-initiated tool or permission request is authorized by this client.
                    try? write(["id": id, "error": ["code": -32601, "message": "Notas does not permit tools or permission escalation."]])
                    onEvent?("notas/blockedTool", params)
                } else { onEvent?(method, params) }
            } else if let id = message["id"] as? Int, let item = pending.removeValue(forKey: id) {
                item.timeout.cancel()
                if let error = message["error"] as? [String: Any] {
                    item.continuation.resume(throwing: AssistantError.message(error["message"] as? String ?? "Codex rejected the request."))
                } else if let result = message["result"] as? [String: Any] { item.continuation.resume(returning: result) }
                else { item.continuation.resume(throwing: AssistantError.message("Codex returned an invalid response.")) }
            }
        }
    }
}
