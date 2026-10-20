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
    var reasoningLabel: String { usesChatCompletions ? "High reasoning" : "Medium reasoning" }
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
