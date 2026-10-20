import Foundation

struct ChatTurn: Sendable {
    let role: String
    let text: String
}

/// One stateless request to an OpenAI-compatible Responses endpoint. The model gets the note snapshot and the
/// conversation text only: no tools, files, or other notes exist for it to reach.
struct ChatClient: Sendable {
    static let defaultBaseURL = URL(string: "https://opencode.ai/inference/go/openai/v1")!
    static let model = "gpt-6-luna"
    static let modelName = "Luna"

    var baseURL = ChatClient.defaultBaseURL
    let apiKey: String
    /// OpenCode routes requests by session; one id per client keeps a conversation's cache warm.
    private let session = UUID().uuidString.lowercased()

    init(apiKey: String, baseURL: URL = ChatClient.defaultBaseURL) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func complete(instructions: String, turns: [ChatTurn], schema: [String: Any]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: "x-opencode-session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Self.model,
            "reasoning": ["effort": "medium"],
            "instructions": instructions,
            "input": turns.map { ["role": $0.role, "content": $0.text] },
            "max_output_tokens": 32_000,
            "text": ["format": ["type": "json_schema", "name": "note_reply", "strict": true, "schema": schema]]
        ]
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
