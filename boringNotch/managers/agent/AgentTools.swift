//
//  AgentTools.swift
//  boringNotch
//
//  The tools the model is allowed to call, and how each one is carried out.
//
//  Most of them are typed: open_app, set_volume, media_control. They map onto
//  AgentAction, which the local matcher already uses and ActionExecutor already
//  knows how to run, so the agent and the fast path do the same thing the same
//  way -- one place to fix a bug in "open chrome".
//
//  That is the point of typed tools. When the model asks to set the volume it
//  says so, in a schema that cannot express anything else, and nothing has to
//  reason about whether a shell string is dangerous. `run_shell` remains as one
//  option among many for the genuinely open-ended cases, and it is the only one
//  that goes near the gate.
//

import Foundation

enum AgentTools {

    /// Definitions sent to the model. Order is stable so it can be cached.
    static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "open_app",
            description: "Open or focus a Mac application by name, e.g. Chrome, Terminal.",
            schema: object(["name": string("Application name, as a person would say it")],
                           required: ["name"])),

        AgentToolDefinition(
            name: "quit_app",
            description: "Quit a running Mac application by name.",
            schema: object(["name": string("Application name")], required: ["name"])),

        AgentToolDefinition(
            name: "open_url",
            description: "Open a URL in the default browser, focusing an existing tab if one matches.",
            schema: object(["url": string("Absolute URL including scheme")], required: ["url"])),

        AgentToolDefinition(
            name: "web_search",
            description: "Search the web or YouTube and show the results.",
            schema: object([
                "query": string("What to search for"),
                "engine": enumeration(["google", "youtube", "youtube_music"],
                                      "Which site to search. Defaults to google."),
            ], required: ["query"])),

        AgentToolDefinition(
            name: "media_control",
            description: "Control playback in the frontmost media app.",
            schema: object([
                "command": enumeration(["play", "pause", "play_pause", "next", "previous"],
                                       "Transport command"),
            ], required: ["command"])),

        AgentToolDefinition(
            name: "set_volume",
            description: "Set system output volume to an absolute level.",
            schema: object(["percent": integer("0 to 100")], required: ["percent"])),

        AgentToolDefinition(
            name: "set_brightness",
            description: "Set display brightness to an absolute level.",
            schema: object(["percent": integer("0 to 100")], required: ["percent"])),

        AgentToolDefinition(
            name: "report",
            description: "Answer a question about what is running on this Mac without a shell.",
            schema: object([
                "kind": enumeration(["running_apps", "open_tabs"], "What to report"),
            ], required: ["kind"])),

        AgentToolDefinition(
            name: "run_shell",
            description: """
            Run one short single-line shell command and return its output. Use \
            this only when no other tool fits. Read-only commands run \
            immediately; anything that changes state stops and asks the user, \
            so prefer the plain read-only form and expect a refusal to be final.
            """,
            schema: object(["command": string("A single-line shell command")],
                           required: ["command"])),
    ]

    /// Works out what a tool call means.
    ///
    /// Bad arguments come back as `.invalid` rather than thrown: the model gets
    /// the message as a tool_result and corrects itself, which is cheaper than
    /// ending the turn and telling the user nothing.
    static func resolve(name: String, input: [String: Any]) -> ToolResolution {
        switch name {
        case "open_app":
            guard let value = string(input, "name") else { return .invalid("open_app needs a name.") }
            return .action(.openApp(name: value))

        case "quit_app":
            guard let value = string(input, "name") else { return .invalid("quit_app needs a name.") }
            return .action(.quitApp(name: value))

        case "open_url":
            guard let value = string(input, "url"), let url = URL(string: value), url.scheme != nil else {
                return .invalid("open_url needs an absolute URL including https://.")
            }
            return .action(.openURL(url))

        case "web_search":
            guard let query = string(input, "query") else { return .invalid("web_search needs a query.") }
            let engine: AgentAction.SearchEngine
            switch string(input, "engine") {
            case "youtube": engine = .youtube
            case "youtube_music": engine = .youtubeMusic
            default: engine = .google
            }
            return .action(.searchWeb(query: query, engine: engine))

        case "media_control":
            switch string(input, "command") {
            case "play": return .action(.media(.play))
            case "pause": return .action(.media(.pause))
            case "play_pause": return .action(.media(.playPause))
            case "next": return .action(.media(.next))
            case "previous": return .action(.media(.previous))
            default: return .invalid("media_control needs one of play, pause, play_pause, next, previous.")
            }

        case "set_volume":
            guard let percent = percent(input) else { return .invalid("set_volume needs percent between 0 and 100.") }
            return .action(.setVolume(percent))

        case "set_brightness":
            guard let percent = percent(input) else { return .invalid("set_brightness needs percent between 0 and 100.") }
            return .action(.setBrightness(percent))

        case "report":
            switch string(input, "kind") {
            case "running_apps": return .action(.report(.runningApps))
            case "open_tabs": return .action(.report(.openTabs))
            default: return .invalid("report needs kind of running_apps or open_tabs.")
            }

        case "run_shell":
            return .shell

        default:
            return .unknown
        }
    }

    // MARK: - Argument reading

    private static func string(_ input: [String: Any], _ key: String) -> String? {
        guard let value = input[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Accepts a number or a numeric string, because models send both, and
    /// clamps rather than rejecting -- "volume 150" means "as loud as it goes".
    private static func percent(_ input: [String: Any]) -> Float? {
        let raw: Double?
        if let number = input["percent"] as? NSNumber {
            raw = number.doubleValue
        } else if let text = input["percent"] as? String {
            raw = Double(text.trimmingCharacters(in: .whitespaces))
        } else {
            raw = nil
        }
        guard let value = raw, value.isFinite else { return nil }
        return Float(max(0, min(100, value)) / 100)
    }

    // MARK: - Schema helpers

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            // The model cannot invent arguments the executor would ignore.
            "additionalProperties": false,
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description, "minimum": 0, "maximum": 100]
    }

    private static func enumeration(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }
}
