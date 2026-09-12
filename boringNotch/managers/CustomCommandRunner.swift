//
//  CustomCommandRunner.swift
//  boringNotch
//
//  Runs the steps of a user-defined command in order.
//
//  Steps that execute arbitrary code — shell, AppleScript, Shortcuts — cannot
//  run inside the app sandbox, so they are handed to the unsandboxed XPC helper.
//  Unlike the agent's commands these are authored by the user in Settings, not
//  produced by a model, so they do not go through AgentGate. What protects the
//  user here is that they wrote the command, plus the per-command confirmation
//  that defaults to on for exactly these step kinds.
//

import AppKit
import Foundation

@MainActor
enum CustomCommandRunner {

    /// Runs every step in order, stopping at the first failure.
    static func run(_ command: CustomCommand) async -> ActionOutcome {
        guard !command.steps.isEmpty else {
            return .fail("\"\(command.name)\" has no steps")
        }

        for (index, step) in command.steps.enumerated() {
            let outcome = await run(step)
            VoiceAuditLog.record(event: outcome.succeeded ? "custom_step" : "custom_step_failed", fields: [
                "command": command.name,
                "step": "\(index + 1)/\(command.steps.count)",
                "kind": step.kind.rawValue,
                "detail": step.summary,
                "outcome": outcome.message,
            ])
            guard outcome.succeeded else {
                return .fail("\(command.name): step \(index + 1) failed — \(outcome.message)")
            }
        }

        let label = command.name.trimmingCharacters(in: .whitespaces)
        return .ok(label.isEmpty ? "Done" : label)
    }

    private static func run(_ step: CommandStep) async -> ActionOutcome {
        let value = step.value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch step.kind {
        case .openURL:
            guard let url = normalizedURL(value) else { return .fail("Invalid URL: \(value)") }
            return await ActionExecutor.run(.openURL(url))

        case .openApp:
            return await ActionExecutor.run(.openApp(name: value))

        case .quitApp:
            return await ActionExecutor.run(.quitApp(name: value))

        case .setVolume:
            return await ActionExecutor.run(.setVolume(Float(step.number / 100)))

        case .adjustVolume:
            return await ActionExecutor.run(.adjustVolume(delta: Float(step.number / 100)))

        case .setBrightness:
            return await ActionExecutor.run(.setBrightness(Float(step.number / 100)))

        case .adjustBrightness:
            return await ActionExecutor.run(.adjustBrightness(delta: Float(step.number / 100)))

        case .media:
            guard let media = mediaCommand(value) else {
                return .fail("Unknown media command \"\(value)\"")
            }
            return await ActionExecutor.run(.media(media))

        case .delay:
            let seconds = max(0, min(30, step.number))
            try? await Task.sleep(for: .seconds(seconds))
            return .ok("Waited \(seconds)s")

        case .speak:
            guard !value.isEmpty else { return .fail("Nothing to speak") }
            return await runInHelper(shell: "/usr/bin/say \(shellQuoted(value))", label: "Spoke")

        case .runShortcut:
            guard !value.isEmpty else { return .fail("No shortcut name") }
            return await runInHelper(
                shell: "/usr/bin/shortcuts run \(shellQuoted(value))",
                label: "Ran shortcut \"\(value)\"")

        case .appleScript:
            guard !value.isEmpty else { return .fail("Empty script") }
            return await runInHelper(
                shell: "/usr/bin/osascript -e \(shellQuoted(value))",
                label: "Ran AppleScript")

        case .shell:
            guard !value.isEmpty else { return .fail("Empty command") }
            return await runInHelper(shell: value, label: "Ran command")
        }
    }

    // MARK: Helpers

    private static func runInHelper(shell: String, label: String) async -> ActionOutcome {
        let result = await XPCHelperClient.shared.runUserShellCommand(shell)
        switch result {
        case let .success(output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok(trimmed.isEmpty ? label : String(trimmed.prefix(200)))
        case let .failure(error):
            return .fail(error.text)
        }
    }

    /// Wraps a string in single quotes for /bin/sh, escaping any it contains.
    private static func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func normalizedURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.contains("://") { return URL(string: raw) }
        return URL(string: "https://\(raw)")
    }

    private static func mediaCommand(_ raw: String) -> AgentAction.MediaCommand? {
        switch raw.lowercased() {
        case "play": return .play
        case "pause", "stop": return .pause
        case "next", "skip": return .next
        case "previous", "prev", "back": return .previous
        case "toggle", "playpause", "play/pause", "": return .playPause
        default: return nil
        }
    }
}
