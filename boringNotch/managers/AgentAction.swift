//
//  AgentAction.swift
//  boringNotch
//
//  The vocabulary of things a voice command can do, and the one place that
//  executes them.
//
//  Everything here runs inside the app sandbox: launching apps and opening URLs
//  go through LaunchServices, media goes through MusicManager, volume through
//  CoreAudio. Nothing here shells out — anything needing a shell belongs to the
//  agent path in the XPC helper, behind the confirm gate.
//

import AppKit
import Foundation

// MARK: - Vocabulary

enum AgentAction: Equatable {
    case openApp(name: String)
    case quitApp(name: String)
    case openURL(URL)
    /// Opens a search results page. Nothing auto-plays — see BrowserTabs.
    case searchWeb(query: String, engine: SearchEngine)
    case media(MediaCommand)
    /// Absolute level, 0...1.
    case setVolume(Float)
    /// Relative change, e.g. +0.1.
    case adjustVolume(delta: Float)
    /// Absolute screen brightness, 0...1.
    case setBrightness(Float)
    case adjustBrightness(delta: Float)
    /// Answers a question locally instead of paying a round trip to the agent.
    case report(Report)

    enum Report: String, Equatable {
        case runningApps
        case openTabs
    }

    enum SearchEngine: String, Equatable {
        case google
        case youtube
        case youtubeMusic

        func url(for query: String) -> URL? {
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            switch self {
            case .google:       return URL(string: "https://www.google.com/search?q=\(q)")
            case .youtube:      return URL(string: "https://www.youtube.com/results?search_query=\(q)")
            case .youtubeMusic: return URL(string: "https://music.youtube.com/search?q=\(q)")
            }
        }
    }

    enum MediaCommand: Equatable {
        case playPause
        case play
        case pause
        case next
        case previous
    }
}

struct ActionOutcome: Equatable {
    let succeeded: Bool
    /// Short phrase for the notch, e.g. "Opened Google Chrome".
    let message: String

    static func ok(_ message: String) -> ActionOutcome { .init(succeeded: true, message: message) }
    static func fail(_ message: String) -> ActionOutcome { .init(succeeded: false, message: message) }
}

// MARK: - Executor

@MainActor
enum ActionExecutor {

    @discardableResult
    static func run(_ action: AgentAction) async -> ActionOutcome {
        switch action {
        case let .openApp(name):
            return openApp(named: name)

        case let .quitApp(name):
            return quitApp(named: name)

        case let .openURL(url):
            return await openOrFocus(url)

        case let .searchWeb(query, engine):
            guard let url = engine.url(for: query) else {
                return .fail("Couldn't build a search for \"\(query)\"")
            }
            NSWorkspace.shared.open(url)
            return .ok("Searching for \"\(query)\"")

        case let .media(command):
            let music = MusicManager.shared
            switch command {
            case .playPause: music.playPause();      return .ok("Toggled playback")
            case .play:      music.play();           return .ok("Playing")
            case .pause:     music.pause();          return .ok("Paused")
            case .next:      music.nextTrack();      return .ok("Next track")
            case .previous:  music.previousTrack();  return .ok("Previous track")
            }

        case let .setVolume(level):
            let clamped = max(0, min(1, level))
            VolumeManager.shared.setAbsolute(Float32(clamped))
            return .ok(clamped == 0 ? "Muted" : "Volume \(Int((clamped * 100).rounded()))%")

        case let .setBrightness(level):
            let clamped = max(0, min(1, level))
            BrightnessManager.shared.setAbsolute(value: clamped)
            return .ok("Brightness \(Int((clamped * 100).rounded()))%")

        case let .adjustBrightness(delta):
            let target = max(0, min(1, BrightnessManager.shared.rawBrightness + delta))
            BrightnessManager.shared.setAbsolute(value: target)
            return .ok("Brightness \(Int((target * 100).rounded()))%")

        case let .report(kind):
            return await report(kind)

        case let .adjustVolume(delta):
            let current = VolumeManager.shared.rawVolume
            let target = max(0, min(1, current + delta))
            VolumeManager.shared.setAbsolute(Float32(target))
            return .ok("Volume \(Int((target * 100).rounded()))%")
        }
    }

    // MARK: Reports

    private static func report(_ kind: AgentAction.Report) async -> ActionOutcome {
        switch kind {
        case .runningApps:
            let names = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
                .sorted()
            guard !names.isEmpty else { return .fail("Nothing seems to be running.") }
            return .ok("\(names.count) apps: " + names.joined(separator: ", "))

        case .openTabs:
            let titles = await BrowserTabs.listOpenTabs()
            guard !titles.isEmpty else { return .fail("No open browser tabs found.") }
            return .ok("\(titles.count) tabs: " + titles.joined(separator: " · "))
        }
    }

    // MARK: URLs

    /// Prefers an already-open tab over opening a duplicate — asking for
    /// "youtube music" when it is already open should switch to it, not stack
    /// another copy. Falls back to opening normally.
    private static func openOrFocus(_ url: URL) async -> ActionOutcome {
        let label = url.host ?? url.absoluteString
        if let host = url.host, let browser = await BrowserTabs.focusTab(matching: host) {
            return .ok("Switched to \(label) in \(browser)")
        }
        NSWorkspace.shared.open(url)
        return .ok("Opened \(label)")
    }

    // MARK: App resolution

    /// Never quits these, whatever is asked.
    private static let unquittable: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
    ]

    private static func quitApp(named name: String) -> ActionOutcome {
        guard let url = resolveApplication(named: name),
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else {
            return .fail("Couldn't find an app called \"\(name)\"")
        }
        let displayName = url.deletingPathExtension().lastPathComponent

        guard bundleID != Bundle.main.bundleIdentifier else {
            return .fail("I'm not going to quit myself.")
        }
        guard !unquittable.contains(bundleID.lowercased()) else {
            return .fail("\(displayName) isn't safe to quit.")
        }

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
        guard !running.isEmpty else {
            return .fail("\(displayName) isn't running")
        }
        // terminate() asks politely; an app with unsaved work can refuse, which
        // is the behaviour we want from a voice command.
        running.forEach { _ = $0.terminate() }
        return .ok("Closed \(displayName)")
    }

    private static func openApp(named name: String) -> ActionOutcome {
        guard let url = resolveApplication(named: name) else {
            return .fail("Couldn't find an app called \"\(name)\"")
        }
        let displayName = url.deletingPathExtension().lastPathComponent
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return .ok("Opened \(displayName)")
    }

    /// Spoken names rarely match bundle names, so a few common ones are mapped
    /// explicitly before falling back to searching the app directories.
    private static let appAliases: [String: String] = [
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "code": "Visual Studio Code",
        "terminal": "Terminal",
        "browser": "Safari",
        "music": "Music",
        "apple music": "Music",
        "settings": "System Settings",
        "system settings": "System Settings",
        "preferences": "System Settings",
        "activity monitor": "Activity Monitor",
    ]

    private static let searchDirectories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Pure filesystem lookup — safe to call off the main actor, which the
    /// intent matcher does.
    nonisolated static func resolveApplication(named rawName: String) -> URL? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }

        let target = (appAliases[name] ?? rawName).lowercased()

        var candidates: [URL] = []
        let fm = FileManager.default
        for directory in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(entry))
            }
        }

        func basename(_ url: URL) -> String {
            url.deletingPathExtension().lastPathComponent.lowercased()
        }

        // Most specific match first, so "mail" doesn't win "Mailbutler".
        if let exact = candidates.first(where: { basename($0) == target }) { return exact }
        if let prefixed = candidates.first(where: { basename($0).hasPrefix(target) }) { return prefixed }
        // Substring matching only for names long enough to be meaningful —
        // otherwise "os" matches "Photos" and "open my os" launches Photos.
        if target.count >= 4,
           let contained = candidates.first(where: { basename($0).contains(target) }) {
            return contained
        }
        return nil
    }
}
