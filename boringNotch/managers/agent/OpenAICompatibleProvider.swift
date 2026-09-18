//
//  OpenAICompatibleProvider.swift
//  boringNotch
//
//  One provider for everything that speaks the OpenAI chat-completions shape,
//  which by now is most things:
//
//    OpenRouter  https://openrouter.ai/api/v1              one key, ~450 models
//    Gemini      https://generativelanguage.googleapis.com/v1beta/openai
//    OpenAI      https://api.openai.com/v1
//    Ollama      http://localhost:11434/v1                 fully offline
//
//  Written rather than pulled in as a dependency on purpose. The Swift packages
//  that do this (llmkit-swift, aikitswift, Conduit) are real and MIT-ish, but
//  the most promising had two stars when this was written, and this app ships a
//  gated shell. A file we can read and test beats a library we cannot.
//
//  TWO THINGS DIFFER FROM ANTHROPIC, and both are silent if you get them wrong:
//
//  1. Tool results are their OWN messages with role "tool", one per call.
//     Anthropic wants every tool_result in a single user turn; OpenAI wants one
//     message each. Same information, opposite shape.
//  2. Tool arguments arrive as a JSON *string* inside the response, not as an
//     object, so they need a second parse.
//

import Foundation

struct OpenAICompatibleProvider: ModelProvider {

    let name: String
    /// Everything before `/chat/completions`. Trailing slash optional.
    let baseURL: URL
    let model: String
    let apiKey: () -> String?

    /// Sent by OpenRouter convention so usage shows up attributed rather than
    /// anonymous. Harmless everywhere else -- unknown headers are ignored.
    private let referer = "https://github.com/jainilDesai/boring.notch"
    private let title = "Brow"

    private let maxTokens = 4096
    private let session: URLSession

    init(name: String, baseURL: URL, model: String, timeout: TimeInterval = 60, apiKey: @escaping () -> String?) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Request

    func send(
        system: String,
        messages: [AgentMessage],
        tools: [AgentToolDefinition]
    ) async throws -> ModelReply {
        guard let key = apiKey(), !key.isEmpty else { throw ProviderError.notConfigured }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(system: system, messages: messages, tools: tools))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, message: Self.errorMessage(from: data))
        }
        return try Self.decode(data)
    }

    /// Built separately so the shape is assertable without a network call.
    func requestBody(
        system: String,
        messages: [AgentMessage],
        tools: [AgentToolDefinition]
    ) -> [String: Any] {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            wire.append(contentsOf: Self.encode(message))
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": wire,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.schema,
                    ] as [String: Any],
                ] as [String: Any]
            }
        }
        return body
    }

    // MARK: - Encoding

    /// One AgentMessage can become SEVERAL wire messages, because a turn
    /// carrying three tool results is three `role: "tool"` messages here.
    private static func encode(_ message: AgentMessage) -> [[String: Any]] {
        var text = ""
        var toolCalls: [[String: Any]] = []
        var results: [[String: Any]] = []

        for block in message.content {
            switch block {
            case let .text(value):
                text += text.isEmpty ? value : " \(value)"

            case let .toolUse(id, name, input):
                // Arguments go out as a JSON STRING, not an object.
                let arguments = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": arguments] as [String: Any],
                ])

            case let .toolResult(toolUseID, resultText, _):
                // No is_error field in this shape -- a failure is just the
                // content of the result, which the model reads either way.
                results.append([
                    "role": "tool",
                    "tool_call_id": toolUseID,
                    "content": resultText,
                ])
            }
        }

        // Tool results replace the turn entirely; they never share a message
        // with user text.
        if !results.isEmpty { return results }

        var wire: [String: Any] = ["role": message.role.rawValue]
        if !toolCalls.isEmpty {
            wire["tool_calls"] = toolCalls
            // An assistant turn that is only tool calls still needs the key
            // present; some servers reject a missing content field outright.
            wire["content"] = text.isEmpty ? NSNull() : text
        } else {
            wire["content"] = text
        }
        return [wire]
    }

    // MARK: - Decoding

    private static func decode(_ data: Data) throws -> ModelReply {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ProviderError.malformedResponse("not an object") }

        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else { throw ProviderError.malformedResponse("no choices") }

        var content: [AgentContent] = []
        if let text = message["content"] as? String, !text.isEmpty {
            content.append(.text(text))
        }

        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            guard
                let function = call["function"] as? [String: Any],
                let name = function["name"] as? String
            else { continue }
            // Some servers omit the id. Synthesising one keeps the loop's
            // result-matching intact rather than dropping the call.
            let id = call["id"] as? String ?? "call_\(content.count)"
            let raw = function["arguments"] as? String ?? "{}"
            let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
                as? [String: Any] ?? [:]
            content.append(.toolUse(id: id, name: name, input: input))
        }

        // finish_reason is the intent; the presence of calls is the fact.
        // Trust the fact -- not every server sets "tool_calls" reliably.
        let wantsTools = content.contains {
            if case .toolUse = $0 { return true } else { return false }
        }
        return ModelReply(content: content, wantsTools: wantsTools)
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = root["message"] as? String { return message }
        return ""
    }
}
