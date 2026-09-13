//
//  AnthropicProvider.swift
//  boringNotch
//
//  Talks to the Anthropic Messages API over plain HTTP.
//
//  There is no official Anthropic SDK for Swift, so this builds the request
//  body and reads the response with JSONSerialization. That is the documented
//  approach for languages without an SDK, not a shortcut -- the wire format is
//  the contract.
//
//  Everything about the conversation shape lives in ModelProvider.swift; this
//  file only translates to and from JSON and reports failures in terms a person
//  talking to their laptop can act on.
//

import Foundation

struct AnthropicProvider: ModelProvider {

    let name = "Anthropic"

    /// The model to ask. Configurable because the right answer depends on what
    /// the user wants: Opus for judgement, Haiku when a voice assistant should
    /// feel instant.
    let model: String

    /// How hard the model should think before answering. Voice commands are
    /// short, concrete tasks, so this defaults low -- effort is the main lever
    /// on how long someone stands in front of their Mac waiting.
    ///
    /// Only sent to models that accept it. See `supportsEffort`.
    let effort: String

    /// Whether this model accepts `output_config.effort`.
    ///
    /// Haiku 4.5 and the older tiers REJECT it with a 400 -- effort is an
    /// Opus/Sonnet/Fable-tier parameter. Brow defaults to Haiku for latency, so
    /// sending it unconditionally would have failed every single request.
    /// Allow-listed by prefix rather than excluded, so a model nobody here has
    /// heard of is sent the minimal request that works everywhere.
    var supportsEffort: Bool {
        ["claude-opus-", "claude-sonnet-5", "claude-sonnet-4-6", "claude-fable-", "claude-mythos-"]
            .contains { model.hasPrefix($0) }
    }

    /// Read fresh on every request rather than captured, so revoking or
    /// changing the key in Settings takes effect on the next sentence.
    let apiKey: () -> String?

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    /// Generous enough that adaptive thinking cannot eat the whole budget and
    /// truncate the answer mid-sentence. Thinking tokens count against this.
    private let maxTokens = 8192

    private let session: URLSession

    init(
        model: String,
        effort: String = "low",
        timeout: TimeInterval = 60,
        apiKey: @escaping () -> String?
    ) {
        self.model = model
        self.effort = effort
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

        let body = requestBody(system: system, messages: messages, tools: tools)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    /// Built separately from sending so the shape can be asserted in tests. A
    /// parameter the chosen model rejects is a 400 on every request, and that
    /// is not something to discover by talking to your laptop.
    func requestBody(
        system: String,
        messages: [AgentMessage],
        tools: [AgentToolDefinition]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map(Self.encode),
        ]
        if supportsEffort {
            body["output_config"] = ["effort": effort]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.schema,
                ] as [String: Any]
            }
        }
        return body
    }

    // MARK: - Encoding

    private static func encode(_ message: AgentMessage) -> [String: Any] {
        [
            "role": message.role.rawValue,
            "content": message.content.map(encode),
        ]
    }

    private static func encode(_ block: AgentContent) -> [String: Any] {
        switch block {
        case let .text(value):
            return ["type": "text", "text": value]
        case let .toolUse(id, name, input):
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        case let .toolResult(toolUseID, text, isError):
            return [
                "type": "tool_result",
                "tool_use_id": toolUseID,
                "content": text,
                "is_error": isError,
            ]
        }
    }

    // MARK: - Decoding

    private static func decode(_ data: Data) throws -> ModelReply {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProviderError.malformedResponse("not an object")
        }

        // Check the stop reason before reading content: a refusal returns HTTP
        // 200 with content that may be empty, and reading it as an answer would
        // report silence rather than a decline.
        let stopReason = root["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = root["stop_details"] as? [String: Any]
            throw ProviderError.refused(details?["explanation"] as? String ?? "")
        }

        guard let rawContent = root["content"] as? [[String: Any]] else {
            throw ProviderError.malformedResponse("no content array")
        }

        var content: [AgentContent] = []
        for block in rawContent {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    content.append(.text(text))
                }
            case "tool_use":
                guard
                    let id = block["id"] as? String,
                    let name = block["name"] as? String
                else { continue }
                // Absent input is an empty object, not a failure: a tool with
                // no required properties is legitimately called with {}.
                let input = block["input"] as? [String: Any] ?? [:]
                content.append(.toolUse(id: id, name: name, input: input))
            default:
                // thinking blocks and anything added later. Ignored rather than
                // rejected -- an unknown block type is not an error, and
                // failing on one would break on the next API addition.
                continue
            }
        }

        return ModelReply(content: content, wantsTools: stopReason == "tool_use")
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return "" }
        return message
    }
}
