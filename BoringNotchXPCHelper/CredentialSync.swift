//
//  CredentialSync.swift
//  BoringNotchXPCHelper
//
//  Keeps ~/.claude/.credentials.json in step with the keychain.
//
//  The Claude CLI stores its OAuth credentials in a keychain item, but cannot
//  read that item when spawned from this XPC service — it reports "Not logged
//  in". It *can* read a credentials file, and `/usr/bin/security` *can* read
//  the keychain from here, so the helper bridges the two.
//
//  The file holds a live OAuth token in plaintext, so it is written 0600 and
//  carries only the `claudeAiOauth` section — never the MCP server tokens that
//  share the same keychain item.
//

import Foundation

enum CredentialSync {

    private static let keychainService = "Claude Code-credentials"

    private static var credentialsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// True when a failure looks like the CLI could not authenticate, and so is
    /// worth one retry after re-syncing.
    static func isAuthError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not logged in")
            || lowered.contains("oauth")
            || lowered.contains("authenticate")
            || lowered.contains("unauthorized")
            || lowered.contains("401")
    }

    /// True when the on-disk token is missing or has expired, so it is worth
    /// re-syncing before even trying.
    static func needsSync() -> Bool {
        guard
            let data = try? Data(contentsOf: credentialsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let expiresAt = oauth["expiresAt"] as? Double
        else { return true }
        // A minute of slack so a token about to lapse mid-request is refreshed.
        return Date().timeIntervalSince1970 * 1000 >= expiresAt - 60_000
    }

    /// Copies the OAuth section from the keychain into the credentials file.
    /// Returns true when the file changed.
    @discardableResult
    static func sync() -> Bool {
        guard let json = readKeychain() else { return false }
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let oauth = root["claudeAiOauth"]
        else { return false }

        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys]
        ) else { return false }

        if let existing = try? Data(contentsOf: credentialsURL), existing == payload {
            return false  // already current
        }

        let directory = credentialsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? payload.write(to: credentialsURL, options: .atomic)) != nil else { return false }
        // .atomic replaces the file, so permissions must be reapplied.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)

        NSLog("[agent] refreshed credentials from keychain")
        return true
    }

    private static func readKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService,
            "-a", NSUserName(),
            "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
