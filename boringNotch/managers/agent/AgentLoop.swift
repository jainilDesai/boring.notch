//
//  AgentLoop.swift
//  boringNotch
//
//  send -> tool calls -> execute -> feed results back -> repeat, until the
//  model stops asking for tools or the turn budget runs out.
//
//  The Claude Code CLI used to own this loop, which is why the agent could only
//  run as its author. Owning it is what BYOK actually costs, and it is the part
//  that has to be right: a loop that never terminates burns money, and one that
//  hands tool results back in the wrong shape silently stops the model making
//  parallel calls.
//
//  Three rules it exists to enforce:
//
//    - BOUNDED. A model that keeps asking for tools is stopped after
//      maxTurns, with whatever it has said so far. There is no path here that
//      loops forever.
//    - CANCELLABLE. Speaking again should abandon the previous question, not
//      queue behind it. Cancellation is checked before every leg.
//    - ALL RESULTS IN ONE MESSAGE. Several tool_use blocks in one reply get
//      several tool_result blocks in ONE user message. Splitting them across
//      messages trains the model out of parallel calls.
//

import Foundation

/// What the loop did, for the notch and the audit log.
struct AgentOutcome {
    let text: String
    /// Names of tools actually run, in order. Surfaced so the UI can say
    /// "checking disk space" rather than spinning silently.
    let toolsUsed: [String]
    let stoppedAtTurnLimit: Bool
}

@MainActor
final class AgentLoop {

    /// Runs one shell command, having screened it. Injected rather than called
    /// directly so the loop can be tested without a helper, a gate, or a Mac.
    typealias ShellRunner = (String) async -> ToolOutcome

    /// Carries out a typed action. Injected for the same reason.
    typealias ActionRunner = (AgentAction) async -> ToolOutcome

    private let provider: ModelProvider
    private let runShell: ShellRunner
    private let runAction: ActionRunner
    private let maxTurns: Int

    /// Called as work happens, so the notch can show something other than a
    /// spinner during a ten-second answer.
    var onProgress: ((String) -> Void)?

    init(
        provider: ModelProvider,
        maxTurns: Int = 6,
        runAction: @escaping ActionRunner,
        runShell: @escaping ShellRunner
    ) {
        self.provider = provider
        self.maxTurns = maxTurns
        self.runAction = runAction
        self.runShell = runShell
    }

    func run(transcript: String, system: String) async throws -> AgentOutcome {
        var messages: [AgentMessage] = [.user(transcript)]
        var toolsUsed: [String] = []
        var lastText = ""

        for turn in 0..<maxTurns {
            try Task.checkCancellation()

            let reply = try await provider.send(
                system: system,
                messages: messages,
                tools: AgentTools.definitions
            )

            if !reply.text.isEmpty { lastText = reply.text }

            let calls = reply.toolCalls
            guard reply.wantsTools, !calls.isEmpty else {
                return AgentOutcome(text: lastText, toolsUsed: toolsUsed, stoppedAtTurnLimit: false)
            }

            // The assistant turn goes back verbatim. Keeping only the text
            // would drop the tool_use blocks the model is waiting on, and the
            // next request would be rejected as malformed.
            messages.append(AgentMessage(role: .assistant, content: reply.content))

            var results: [AgentContent] = []
            for call in calls {
                try Task.checkCancellation()
                toolsUsed.append(call.name)
                onProgress?(describe(call.name, input: call.input))

                // A failed tool still gets a result. Dropping it leaves the
                // model waiting on an answer that never comes, and makes the
                // next request malformed.
                let outcome = await perform(name: call.name, input: call.input)
                results.append(.toolResult(
                    toolUseID: call.id, text: outcome.text, isError: outcome.isError))
            }

            // One message, every result. See the note at the top.
            messages.append(AgentMessage(role: .user, content: results))

            if turn == maxTurns - 1 {
                return AgentOutcome(
                    text: lastText.isEmpty ? "That needed more steps than I'm allowed to take." : lastText,
                    toolsUsed: toolsUsed,
                    stoppedAtTurnLimit: true)
            }
        }

        return AgentOutcome(text: lastText, toolsUsed: toolsUsed, stoppedAtTurnLimit: true)
    }

    // MARK: - Dispatch

    private func perform(name: String, input: [String: Any]) async -> ToolOutcome {
        switch AgentTools.resolve(name: name, input: input) {
        case let .action(action):
            return await runAction(action)

        case let .invalid(message):
            return .failed(message)

        case .unknown:
            // The model invented a tool. Say so plainly and name it; that
            // corrects the next turn more reliably than a generic error.
            return .failed("No tool named \(name). Use one of the tools provided.")

        case .shell:
            guard let command = (input["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
            else {
                return .failed("run_shell needs a command.")
            }
            return await runShell(command)
        }
    }

    /// Short, human phrasing for the notch. Not for the model.
    private func describe(_ name: String, input: [String: Any]) -> String {
        switch name {
        case "open_app": return "Opening \(input["name"] as? String ?? "app")"
        case "quit_app": return "Closing \(input["name"] as? String ?? "app")"
        case "open_url": return "Opening a link"
        case "web_search": return "Searching"
        case "media_control": return "Playback"
        case "set_volume": return "Setting volume"
        case "set_brightness": return "Setting brightness"
        case "report": return "Checking"
        case "run_shell": return "Running a command"
        default: return "Working"
        }
    }
}
