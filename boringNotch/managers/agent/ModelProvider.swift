//
//  ModelProvider.swift
//  boringNotch
//
//  The seam between Brow and whatever model answers it.
//
//  Today the agent shells out to the Claude Code CLI, which authenticates as
//  the author and cannot be shipped to anyone else. This protocol is what
//  replaces that: one request shape, one reply shape, and a provider behind it
//  that the user configures with their own key.
//
//  Deliberately small. A provider takes a conversation and a tool list and
//  returns either an answer or some tool calls. It does not own the loop, does
//  not execute anything, and does not know what a gate is -- those belong to
//  AgentLoop, which is the part worth testing.
//

import Foundation

// MARK: - Conversation

/// One block of content. Mirrors the wire format rather than inventing a
/// parallel vocabulary, because every provider worth supporting speaks a
/// variation of it and the translation costs nothing here.
enum AgentContent {
    case text(String)
    /// The model wants a tool run. `input` is arbitrary JSON by definition --
    /// it is whatever the tool's schema described.
    case toolUse(id: String, name: String, input: [String: Any])
    /// The answer to a `toolUse`, sent back on the next turn.
    case toolResult(toolUseID: String, text: String, isError: Bool)
}

struct AgentMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let content: [AgentContent]

    static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, content: [.text(text)])
    }
}

/// A tool the model may call. `schema` is a JSON Schema object.
struct AgentToolDefinition {
    let name: String
    let description: String
    let schema: [String: Any]
}

/// What a provider returns for one turn.
struct ModelReply {
    /// Everything the model said, in order, to be appended to the conversation
    /// verbatim. Replaying the assistant turn exactly is required -- dropping
    /// the tool_use blocks and keeping only the text loses the call the model
    /// is waiting on an answer for.
    let content: [AgentContent]
    /// True when the model is waiting on tool results rather than finished.
    let wantsTools: Bool

    var text: String {
        content.compactMap { if case let .text(value) = $0 { return value } else { return nil } }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var toolCalls: [(id: String, name: String, input: [String: Any])] {
        content.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) } else { return nil }
        }
    }
}

/// What running a tool produced.
///
/// A failure here is DATA, not a thrown error: it goes back to the model as a
/// tool_result with is_error set, and the model gets to respond to it. Throwing
/// would end the turn and leave the user with nothing.
enum ToolOutcome: Equatable {
    case ok(String)
    case failed(String)

    var text: String {
        switch self {
        case let .ok(value), let .failed(value): return value
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// What a tool name and its arguments turned out to mean.
enum ToolResolution {
    /// A typed action the app can carry out directly.
    case action(AgentAction)
    /// The arguments did not make sense. The message goes back to the model.
    case invalid(String)
    /// Not a typed action -- `run_shell`, which the loop gates separately.
    case shell
    /// The model named a tool that does not exist.
    case unknown
}

enum ProviderError: LocalizedError {
    case notConfigured
    case http(status: Int, message: String)
    case transport(String)
    case malformedResponse(String)
    /// The model declined the request outright.
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No API key set. Add one in Settings → Voice."
        case let .http(status, message):
            // 401 and 429 are the two the user can actually act on, so say what
            // they mean rather than printing a status code at someone talking
            // to their laptop.
            switch status {
            case 401, 403: return "That API key was rejected. Check it in Settings."
            case 429: return "Rate limited. Try again in a moment."
            case 500...599: return "The model service is having trouble. Try again."
            default: return message.isEmpty ? "Request failed (\(status))." : message
            }
        case let .transport(message):
            return "Couldn't reach the model: \(message)"
        case let .malformedResponse(detail):
            return "Unexpected response from the model: \(detail)"
        case let .refused(reason):
            return reason.isEmpty ? "The model declined that request." : reason
        }
    }
}

// MARK: - Provider

protocol ModelProvider {
    /// Human-readable, for Settings and for error messages.
    var name: String { get }

    /// One turn. Returns what the model said; never executes anything.
    func send(
        system: String,
        messages: [AgentMessage],
        tools: [AgentToolDefinition]
    ) async throws -> ModelReply
}
