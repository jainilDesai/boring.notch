//
//  LocalIntentMatcher.swift
//  boringNotch
//
//  The fast path. Matches a handful of common spoken commands to an AgentAction
//  in about a millisecond, so "open chrome" doesn't wait ~4s for a round trip to
//  Claude.
//
//  Deliberately conservative: a false positive executes something the user did
//  not ask for, which is far worse than falling through to the agent. Every
//  pattern is anchored, and bare verbs ("open", "play it") do not match.
//

import Foundation

enum LocalIntentMatcher {

    /// Returns nil when nothing matches confidently — the caller should fall
    /// through to the agent rather than guess.
    static func match(_ transcript: String) -> AgentAction? {
        let text = normalize(transcript)
        guard !text.isEmpty else { return nil }

        if let action = matchMedia(text) { return action }
        if let action = matchVolume(text) { return action }
        if let action = matchBrightness(text) { return action }
        if let action = matchReport(text) { return action }
        if let action = matchSearch(text) { return action }
        if let action = matchQuit(text) { return action }
        if let action = matchOpen(text) { return action }
        return nil
    }

    // MARK: Normalisation

    /// Lowercases, strips punctuation and filler, collapses whitespace.
    private static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()
        // Only strip punctuation that ends a word, so domains keep their dots
        // ("example.com" must not become "example com").
        text = text.replacingOccurrences(of: "[.,!?;:](?=\\s|$)", with: " ", options: .regularExpression)
        // Speech gives "50%" or "50 percent" depending on phrasing; normalise
        // to one form so the percent patterns only need to handle one.
        text = text.replacingOccurrences(of: "%", with: " percent")
        for filler in ["please ", "can you ", "could you ", "hey ", "now "] {
            text = text.replacingOccurrences(of: filler, with: " ")
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Media

    private static let mediaPhrases: [(phrases: Set<String>, command: AgentAction.MediaCommand)] = [
        (["pause", "pause music", "pause the music", "pause it", "stop music", "stop the music"], .pause),
        (["play", "play music", "play the music", "resume", "resume music", "unpause"], .play),
        (["play pause", "toggle playback", "toggle music"], .playPause),
        (["next", "next song", "next track", "skip", "skip song", "skip this song"], .next),
        (["previous", "previous song", "previous track", "last song", "go back a song"], .previous),
    ]

    private static func matchMedia(_ text: String) -> AgentAction? {
        for entry in mediaPhrases where entry.phrases.contains(text) {
            return .media(entry.command)
        }
        return nil
    }

    // MARK: Volume

    private static func matchVolume(_ text: String) -> AgentAction? {
        if ["mute", "mute it", "mute the volume", "silence"].contains(text) {
            return .setVolume(0)
        }
        if ["volume up", "turn it up", "turn the volume up", "louder", "increase volume"].contains(text) {
            return .adjustVolume(delta: 0.1)
        }
        if ["volume down", "turn it down", "turn the volume down", "quieter", "decrease volume"].contains(text) {
            return .adjustVolume(delta: -0.1)
        }
        // "set volume to 40", "volume 40 percent"
        let patterns = [
            "^(?:set )?volume (?:to )?(\\d{1,3})(?: percent)?$",
            "^(?:set )?the volume (?:to )?(\\d{1,3})(?: percent)?$",
        ]
        for pattern in patterns {
            if let value = firstCapture(in: text, pattern: pattern), let percent = Int(value), percent <= 100 {
                return .setVolume(Float(percent) / 100)
            }
        }
        return nil
    }

    // MARK: Brightness

    private static func matchBrightness(_ text: String) -> AgentAction? {
        if ["brightness up", "brighter", "increase brightness", "turn up the brightness"].contains(text) {
            return .adjustBrightness(delta: 0.1)
        }
        if ["brightness down", "dimmer", "darker", "decrease brightness", "turn down the brightness"].contains(text) {
            return .adjustBrightness(delta: -0.1)
        }
        // "change brightness to 50", "set the brightness to 50 percent", "brightness 50"
        let patterns = [
            "^(?:set|change|make) (?:the )?brightness (?:to |at )?(\\d{1,3})(?: percent)?$",
            "^brightness (?:to )?(\\d{1,3})(?: percent)?$",
        ]
        for pattern in patterns {
            if let value = firstCapture(in: text, pattern: pattern),
               let percent = Int(value), percent <= 100 {
                return .setBrightness(Float(percent) / 100)
            }
        }
        return nil
    }

    // MARK: Reports

    private static func matchReport(_ text: String) -> AgentAction? {
        let apps: Set<String> = [
            "what apps are running", "which apps are running", "check which apps are running",
            "what is running", "what's running", "list running apps", "show running apps",
        ]
        let tabs: Set<String> = [
            "what tabs are open", "which tabs are open", "check which tabs are open",
            "list open tabs", "show open tabs", "what tabs do i have open",
            "check which are the open tabs",
        ]
        if apps.contains(text) { return .report(.runningApps) }
        if tabs.contains(text) { return .report(.openTabs) }
        return nil
    }

    // MARK: Search

    /// "play X on youtube", "search for X", "google X".
    /// Opens the results page — nothing auto-plays.
    private static func matchSearch(_ text: String) -> AgentAction? {
        let rules: [(pattern: String, engine: AgentAction.SearchEngine)] = [
            ("^(?:play|find) (.+) on youtube music$", .youtubeMusic),
            ("^(?:play|find) (.+) on youtube$", .youtube),
            ("^(?:play|find) (.+) on music$", .youtubeMusic),
            ("^search youtube for (.+)$", .youtube),
            ("^(?:search|look) (?:for|up) (.+)$", .google),
            ("^google (.+)$", .google),
        ]
        for rule in rules {
            if let query = firstCapture(in: text, pattern: rule.pattern) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return .searchWeb(query: trimmed, engine: rule.engine)
                }
            }
        }

        // Bare "play <track>". Exact transport phrases are matched earlier, but
        // vague objects still reach here — "play it" means resume, not a song
        // called "it", so those fall through to the agent instead.
        if let query = firstCapture(in: text, pattern: "^play (.+)$") {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let vague: Set<String> = [
                "it", "this", "that", "them", "more", "again",
                "music", "song", "a song", "the song", "some music",
                "something", "anything", "something else",
            ]
            if !trimmed.isEmpty, !vague.contains(trimmed) {
                return .searchWeb(query: trimmed, engine: .youtubeMusic)
            }
        }
        return nil
    }

    // MARK: Quit

    private static func matchQuit(_ text: String) -> AgentAction? {
        let verbs = ["close ", "quit ", "shut down ", "kill "]
        guard let verb = verbs.first(where: { text.hasPrefix($0) }) else { return nil }

        var target = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        for article in ["the ", "my "] where target.hasPrefix(article) {
            target = String(target.dropFirst(article.count))
        }
        target = target
            .replacingOccurrences(of: " app$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !target.isEmpty, !target.contains(" and "), !target.contains(" then ") else { return nil }
        // Only quit something that actually resolves to an app, so "close the
        // door" or "close that tab" falls through instead of guessing.
        guard ActionExecutor.resolveApplication(named: target) != nil else { return nil }
        return .quitApp(name: target)
    }

    // MARK: Open

    /// Spoken site names that have no local app.
    private static let knownSites: [String: String] = [
        "youtube": "https://www.youtube.com",
        "youtube music": "https://music.youtube.com",
        "music youtube": "https://music.youtube.com",
        "github": "https://github.com",
        "gmail": "https://mail.google.com",
        "google": "https://www.google.com",
        "twitter": "https://twitter.com",
        "reddit": "https://www.reddit.com",
        "linkedin": "https://www.linkedin.com",
        "chatgpt": "https://chatgpt.com",
        "claude": "https://claude.ai",
        // Personal sites belong in user-defined commands (Settings > Commands),
        // not hardcoded here — this file is public, and a hardcoded alias needs
        // a rebuild for every new site.
    ]

    private static func matchOpen(_ text: String) -> AgentAction? {
        // "go to X" means the website; "launch X" means the app. Getting this
        // backwards opens GitHub Desktop when you asked for github.com.
        let siteFirstVerbs = ["go to ", "visit "]
        let appFirstVerbs = ["open ", "launch ", "start ", "switch to "]

        let verb: String
        let prefersSite: Bool
        if let match = siteFirstVerbs.first(where: { text.hasPrefix($0) }) {
            verb = match
            prefersSite = true
        } else if let match = appFirstVerbs.first(where: { text.hasPrefix($0) }) {
            verb = match
            prefersSite = false
        } else {
            return nil
        }

        var target = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }

        // "open chrome and go to github" is two steps — leave it to the agent.
        if target.contains(" and ") || target.contains(" then ") { return nil }

        for article in ["the ", "my ", "a "] where target.hasPrefix(article) {
            target = String(target.dropFirst(article.count))
        }
        target = target
            .replacingOccurrences(of: " app$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " website$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }

        // A bare domain is always a URL, whatever the verb: "open example.com".
        let looksLikeDomain = target.range(
            of: "^[a-z0-9-]+(\\.[a-z0-9-]+)+$", options: .regularExpression) != nil
        if looksLikeDomain, let url = URL(string: "https://\(target)") {
            return .openURL(url)
        }

        let site: AgentAction? = knownSites[target].flatMap(URL.init(string:)).map { .openURL($0) }
        let app: AgentAction? = ActionExecutor.resolveApplication(named: target) != nil
            ? .openApp(name: target)
            : nil

        return prefersSite ? (site ?? app) : (app ?? site)
    }

    // MARK: Helpers

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
