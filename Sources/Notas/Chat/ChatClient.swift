import Foundation

enum ChatModel: String, CaseIterable, Identifiable, Sendable {
    case luna = "gpt-6-luna"
    case luna56 = "gpt-5.6-luna"
    case grok = "grok-4.7"
    case muse = "muse-spark-1.3-contributor"
    case deepseekFlash = "deepseek-v4.1-flash"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .luna: "GPT 6 Luna"
        case .luna56: "GPT 5.6 Luna"
        case .grok: "Grok 4.7"
        case .muse: "Muse Spark 1.3 Contributor"
        case .deepseekFlash: "DeepSeek V4.1 Flash"
        }
    }

    var usesChatCompletions: Bool { self == .deepseekFlash }
    /// The usual setting. A restructure asks for medium; DeepSeek stays on high.
    var reasoningLabel: String { usesChatCompletions ? "High reasoning" : "Brief reasoning" }
}

struct ChatStreamUpdate: Sendable {
    var thought: String
    var visibleReply: String
    var output: String
    var finished: Bool
}

struct ChatTurn: Sendable {
    let role: String
    let text: String
}

/// One stateless request to an OpenAI-compatible endpoint. The model gets the note snapshot and the
/// conversation text only: no tools, files, or other notes exist for it to reach.
struct ChatClient: Sendable {
    static let defaultBaseURL = URL(string: "https://opencode.ai/inference/go/openai/v1")!

    var baseURL = ChatClient.defaultBaseURL
    let apiKey: String
    let model: ChatModel
    /// OpenCode routes requests by session; one id per client keeps a conversation's cache warm.
    private let session = UUID().uuidString.lowercased()

    init(apiKey: String, baseURL: URL = ChatClient.defaultBaseURL, model: ChatModel = .luna) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func complete(instructions: String, turns: [ChatTurn], schema: [String: Any]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent(model.usesChatCompletions ? "chat/completions" : "responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: "x-opencode-session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Notas/1.0", forHTTPHeaderField: "User-Agent")
        let body: [String: Any]
        if model.usesChatCompletions {
            let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
            body = [
                "model": model.rawValue,
                "reasoning_effort": "high",
                "messages": [["role": "system", "content": instructions + "\nReturn only a JSON object matching this schema:\n" + schemaText]]
                    + turns.map { ["role": $0.role, "content": $0.text] },
                "max_tokens": 32_000,
                "response_format": ["type": "json_object"]
            ]
        } else {
            body = [
                "model": model.rawValue,
                "reasoning": ["effort": "medium"],
                "instructions": instructions,
                "input": turns.map { ["role": $0.role, "content": $0.text] },
                "max_output_tokens": 32_000,
                "text": ["format": ["type": "json_schema", "name": "note_reply", "strict": true, "schema": schema]]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.urlSession.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw AssistantError.message("You appear to be offline. Check your connection and try again.")
            case .timedOut:
                throw AssistantError.message("The assistant took too long to answer. Try again.")
            default:
                throw AssistantError.message("The assistant couldn't be reached. \(error.localizedDescription)")
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else { throw Self.failure(status: status, json: json) }
        guard let json else { throw AssistantError.message("The assistant sent an unreadable response.") }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AssistantError.message(message)
        }
        if model.usesChatCompletions {
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else {
                throw AssistantError.message("The assistant didn't return a reply.")
            }
            if choice["finish_reason"] as? String == "length" {
                throw AssistantError.message("The reply was cut off. Try a shorter request or a smaller note.")
            }
            if choice["finish_reason"] as? String == "content_filter" || message["refusal"] as? String != nil {
                throw AssistantError.message("The assistant declined this request.")
            }
            guard choice["finish_reason"] as? String == "stop",
                  let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantError.message("The assistant didn't return a reply.")
            }
            return text
        }
        return try Self.outputText(in: json)
    }

    /// Streams a Responses reply. Reasoning summary deltas arrive before the answer. Yields are
    /// coalesced to about 80ms, and the final yield always carries the full output.
    func stream(instructions: String, turns: [ChatTurn], schema: [String: Any], effort: String) -> AsyncThrowingStream<ChatStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.readStream(instructions: instructions, turns: turns, schema: schema, effort: effort, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readStream(instructions: String, turns: [ChatTurn], schema: [String: Any], effort: String, continuation: AsyncThrowingStream<ChatStreamUpdate, Error>.Continuation) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: "x-opencode-session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Notas/1.0", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": model.rawValue,
            "reasoning": ["effort": effort, "summary": "auto"],
            "instructions": instructions,
            "input": turns.map { ["role": $0.role, "content": $0.text] },
            "max_output_tokens": 32_000,
            "stream": true,
            "text": ["format": ["type": "json_schema", "name": "note_reply", "strict": true, "schema": schema]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (asyncBytes, response) = try await Self.urlSession.bytes(for: request) }
        catch { throw Self.transport(error) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(status) else {
            let data = try await Self.collect(asyncBytes)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Self.failure(status: status, json: json)
        }
        if !contentType.contains("text/event-stream") {
            let data = try await Self.collect(asyncBytes)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw AssistantError.message("The assistant sent an unreadable response.")
            }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw AssistantError.message(message)
            }
            let text = try Self.outputText(in: json)
            continuation.yield(ChatStreamUpdate(thought: "", visibleReply: Self.visibleReply(in: text), output: text, finished: true))
            return
        }
        var thought = "", output = "", finished = false
        var lastYield = ContinuousClock.now - .seconds(1)
        func emit(force: Bool) {
            let now = ContinuousClock.now
            if !force, now - lastYield < .milliseconds(80) { return }
            lastYield = now
            continuation.yield(ChatStreamUpdate(thought: thought, visibleReply: Self.visibleReply(in: output), output: output, finished: force))
        }
        do {
        for try await line in asyncBytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                finished = true
                emit(force: true)
                return
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw AssistantError.message(message)
            }
            switch json["type"] as? String ?? "" {
            case "response.reasoning_summary_text.delta":
                if let delta = json["delta"] as? String { thought += delta; emit(force: false) }
            case "response.reasoning_summary_text.done":
                if let text = json["text"] as? String, !text.isEmpty { thought = text }
                emit(force: false)
            case "response.output_text.delta":
                if let delta = json["delta"] as? String { output += delta; emit(force: false) }
            case "response.output_text.done":
                if let text = json["text"] as? String, !text.isEmpty { output = text }
                emit(force: false)
            case "response.refusal.delta", "response.refusal.done":
                throw AssistantError.message("The assistant declined this request.")
            case "response.incomplete":
                throw AssistantError.message("The reply was cut off. Try a shorter request or a smaller note.")
            case "response.completed":
                if let response = json["response"] as? [String: Any] {
                    if response["status"] as? String == "incomplete" {
                        throw AssistantError.message("The reply was cut off. Try a shorter request or a smaller note.")
                    }
                    if let text = try? Self.outputText(in: response) { output = text }
                }
                finished = true
                emit(force: true)
                return
            case "error":
                let message = (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String)
                throw AssistantError.message(message ?? "OpenCode returned an error.")
            default:
                break
            }
        }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.transport(error)
        }
        guard finished else { throw AssistantError.message("The assistant didn't return a reply.") }
    }

    /// The reply field of a partial note-edit JSON object. Raw JSON stays hidden until that string begins.
    static func visibleReply(in json: String) -> String {
        let chars = Array(json)
        let needle = Array("\"reply\"")
        guard needle.count <= chars.count else { return "" }
        var start = 0
        while start + needle.count <= chars.count {
            if Array(chars[start..<(start + needle.count)]) == needle { break }
            start += 1
        }
        guard start + needle.count <= chars.count else { return "" }
        var index = start + needle.count
        while index < chars.count, chars[index].isWhitespace || chars[index] == ":" { index += 1 }
        guard index < chars.count, chars[index] == "\"" else { return "" }
        index += 1
        var result = ""
        var escaped = false
        while index < chars.count {
            let character = chars[index]
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\"", "\\", "/": result.append(character)
                case "u":
                    guard index + 4 < chars.count else { return result }
                    let hex = String(chars[(index + 1)...(index + 4)])
                    guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { return result }
                    result.append(Character(scalar))
                    index += 4
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    private static func outputText(in json: [String: Any]) throws -> String {
        if json["status"] as? String == "incomplete" {
            throw AssistantError.message("The reply was cut off. Try a shorter request or a smaller note.")
        }
        for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "refusal" {
                    throw AssistantError.message("The assistant declined this request.")
                }
                if part["type"] as? String == "output_text", let text = part["text"] as? String { return text }
            }
        }
        throw AssistantError.message("The assistant didn't return a reply.")
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private static func transport(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        if error.code == .cancelled { return CancellationError() }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return AssistantError.message("You appear to be offline. Check your connection and try again.")
        case .timedOut:
            return AssistantError.message("The assistant took too long to answer. Try again.")
        default:
            return AssistantError.message("The assistant couldn't be reached. \(error.localizedDescription)")
        }
    }

    private static func failure(status: Int, json: [String: Any]?) -> AssistantError {
        let detail = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401, 403:
            return .message("OpenCode rejected the API key. Create a new key in the OpenCode Console, then replace it from the chat menu.")
        case 429:
            return .message("Your OpenCode usage limit was reached. Try again later or check your plan.")
        case 500...599:
            return .message("OpenCode is having trouble right now. Try again in a moment.")
        default:
            return .message(detail ?? "OpenCode returned an error (\(status)).")
        }
    }
}
