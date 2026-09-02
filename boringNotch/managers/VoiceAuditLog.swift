//
//  VoiceAuditLog.swift
//  boringNotch
//
//  Append-only record of every voice session: what was heard, what it matched,
//  and what happened. One JSON object per line.
//
//  NSLog alone proved useless for after-the-fact debugging, and once the agent
//  can run shell commands an durable record of what it was asked to do stops
//  being a convenience. The Stage C confirm gate writes its allow/deny
//  decisions into this same file.
//

import Foundation

enum VoiceAuditLog {

    /// Inside the app container:
    /// ~/Library/Containers/com.jainildesai.brow/Data/Library/Application Support/Brow/voice.log
    static let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Brow", isDirectory: true)
            .appendingPathComponent("voice.log")
    }()

    /// Trim once past this size so the file cannot grow without bound.
    private static let maxBytes = 1_000_000

    private static let queue = DispatchQueue(label: "com.jainildesai.brow.voiceaudit")

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Records one entry. Never throws — logging must not break a voice session.
    static func record(event: String, fields: [String: String] = [:]) {
        var payload: [String: String] = ["ts": formatter.string(from: Date()), "event": event]
        payload.merge(fields) { _, new in new }

        queue.async {
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                var line = String(data: data, encoding: .utf8)
            else { return }
            line += "\n"

            let fm = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))

            trimIfNeeded()
        }
    }

    /// Drops the oldest half when the file gets large. Called on `queue`.
    private static func trimIfNeeded() {
        guard
            let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int,
            size > maxBytes,
            let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
