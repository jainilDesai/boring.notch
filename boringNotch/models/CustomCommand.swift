//
//  CustomCommand.swift
//  boringNotch
//
//  User-defined voice commands. A command is one or more trigger phrases and an
//  ordered list of steps, so "kaboom" can mute the volume, say something and
//  open a page in one go.
//
//  These are checked BEFORE the built-in intent matcher, so a user command can
//  deliberately override a built-in one.
//

import Defaults
import Foundation

// MARK: - Step

/// One action in a command.
///
/// Modelled as a flat struct rather than an enum with associated values: it
/// keeps `Codable` trivial and makes the settings editor much simpler, at the
/// cost of `value`/`number` meaning different things per kind.
struct CommandStep: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Hashable {
        case openURL
        case openApp
        case quitApp
        case shell
        case appleScript
        case runShortcut
        case setVolume
        case adjustVolume
        case setBrightness
        case adjustBrightness
        case media
        case speak
        case delay

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openURL: return "Open URL"
            case .openApp: return "Open app"
            case .quitApp: return "Quit app"
            case .shell: return "Run shell command"
            case .appleScript: return "Run AppleScript"
            case .runShortcut: return "Run Shortcut"
            case .setVolume: return "Set volume"
            case .adjustVolume: return "Change volume by"
            case .setBrightness: return "Set brightness"
            case .adjustBrightness: return "Change brightness by"
            case .media: return "Media control"
            case .speak: return "Speak text"
            case .delay: return "Wait"
            }
        }

        /// Label for the text field, or nil when the step takes no text.
        var valueLabel: String? {
            switch self {
            case .openURL: return "URL"
            case .openApp, .quitApp: return "App name"
            case .shell: return "Command"
            case .appleScript: return "Script"
            case .runShortcut: return "Shortcut name"
            case .media: return "play, pause, next, previous, toggle"
            case .speak: return "Text"
            default: return nil
            }
        }

        /// Label for the numeric field, or nil when the step takes no number.
        var numberLabel: String? {
            switch self {
            case .setVolume, .setBrightness: return "Percent (0–100)"
            case .adjustVolume, .adjustBrightness: return "Change by percent (±)"
            case .delay: return "Seconds"
            default: return nil
            }
        }

        /// Steps that run arbitrary code and therefore default to confirming.
        var isPowerful: Bool {
            self == .shell || self == .appleScript || self == .runShortcut
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .openURL
    var value: String = ""
    var number: Double = 0

    /// Short one-line description for the command list.
    var summary: String {
        switch kind {
        case .setVolume, .setBrightness:
            return "\(kind.title) \(Int(number))%"
        case .adjustVolume, .adjustBrightness:
            return "\(kind.title) \(number > 0 ? "+" : "")\(Int(number))%"
        case .delay:
            return "Wait \(number)s"
        default:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? kind.title : "\(kind.title): \(trimmed.prefix(48))"
        }
    }
}

// MARK: - Command

struct CustomCommand: Codable, Equatable, Identifiable, Hashable, Defaults.Serializable {
    var id: UUID = UUID()
    var name: String = ""
    /// Spoken triggers. Matched case-insensitively after normalisation.
    var phrases: [String] = []
    var steps: [CommandStep] = []
    /// Ask before running. Defaults to true when any step runs arbitrary code.
    var requiresConfirmation: Bool = false
    var isEnabled: Bool = true

    var runsArbitraryCode: Bool { steps.contains { $0.kind.isPowerful } }

    /// Normalised trigger phrases, empty ones dropped.
    var normalizedPhrases: [String] {
        phrases
            .map { CustomCommand.normalize($0) }
            .filter { !$0.isEmpty }
    }

    /// Must match the intent matcher's normalisation closely enough that what a
    /// user types as a trigger is what speech recognition will produce.
    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()
        text = text.replacingOccurrences(of: "[.,!?;:]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "%", with: " percent")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Store

@MainActor
final class CustomCommandStore: ObservableObject {
    static let shared = CustomCommandStore()

    @Published var commands: [CustomCommand] {
        didSet { Defaults[.customCommands] = commands }
    }

    private init() {
        commands = Defaults[.customCommands]
    }

    /// Exact match on any trigger phrase of an enabled command.
    ///
    /// Deliberately exact rather than fuzzy: these can run shell commands, and a
    /// loose match on a misheard phrase is exactly the failure worth avoiding.
    func match(_ transcript: String) -> CustomCommand? {
        let needle = CustomCommand.normalize(transcript)
        guard !needle.isEmpty else { return nil }
        return commands.first { command in
            command.isEnabled && command.normalizedPhrases.contains(needle)
        }
    }

    func add(_ command: CustomCommand) { commands.append(command) }

    func update(_ command: CustomCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command
    }

    func delete(_ command: CustomCommand) {
        commands.removeAll { $0.id == command.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
    }
}
