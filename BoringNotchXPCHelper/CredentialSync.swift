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

    /// The LaunchAgent that mirrors the keychain into the credentials file.
    /// Must match the Label in com.jainildesai.brow.credentials.plist.
    private static let mirrorLabel = "com.jainildesai.brow.credentials"

    /// Diagnostics land in a file because NSLog from this helper is not
    /// retrievable via `log show`.
    private static var logURL: URL {
        AgentGate.directory.appendingPathComponent("agent.log")
    }

    static func note(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

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

    /// Makes sure the credentials file is usable before the agent is launched.
    ///
    /// This helper cannot read the login keychain — `security` fails here, which
    /// is the entire reason the file bridge exists — so when the token has
    /// lapsed there is nothing it can do on its own. What it *can* do is ask
    /// launchd to run the mirror LaunchAgent, which lives in the user's Aqua
    /// session where the keychain is reachable, and wait briefly for the file to
    /// reappear.
    ///
    /// This replaces deleting the expired file. Deleting was justified as
    /// letting the CLI fall back to the keychain, but the CLI cannot reach the
    /// keychain from here either, so it only ever left the agent with nothing —
    /// and threw away the refresh token, the one thing that could have renewed
    /// the session without a keychain read at all.
    ///
    /// The mirror runs on a 10-minute timer that does not fire while the Mac is
    /// asleep. Waking the Mac and speaking inside that window is the common way
    /// this used to fail, and it failed with "Not logged in" rather than
    /// anything that pointed at a stale token.
    @discardableResult
    static func ensureUsable() -> Bool {
        guard needsSync() else { return true }

        note("credentials missing or expired — asking the mirror to run")
        guard requestMirrorRun() else {
            note("could not start the mirror LaunchAgent")
            return FileManager.default.fileExists(atPath: credentialsURL.path)
        }

        // The mirror is a keychain read and a small write. It finishes well
        // inside this, and the budget is spent only on a cold path.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !needsSync() {
                note("credentials refreshed by the mirror")
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // The keychain itself can hold an expired token, if nothing has run the
        // CLI in the user's session for longer than the token's lifetime. Go on
        // anyway: the file still carries a refresh token, and the CLI renews
        // itself from that more often than not. Failing here would turn a
        // recoverable state into a certain failure.
        note("mirror ran but the token is still stale — trying the CLI anyway")
        return FileManager.default.fileExists(atPath: credentialsURL.path)
    }

    /// Asks launchd to run the credential mirror now, rather than waiting for
    /// its next 10-minute tick.
    private static func requestMirrorRun() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // -k restarts it if a run is already in flight, so a wedged run cannot
        // leave this waiting on a tick that never comes.
        process.arguments = [
            "kickstart", "-k", "gui/\(getuid())/\(mirrorLabel)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Copies the OAuth section from the keychain into the credentials file.
    /// Returns true when the file changed.
    @discardableResult
    static func sync() -> Bool {
        guard let json = readKeychain() else {
            note("keychain read FAILED — the helper cannot reach the keychain")
            return false
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let oauth = root["claudeAiOauth"]
        else {
            note("keychain read ok but no claudeAiOauth section")
            return false
        }

        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys]
        ) else { return false }

        if let existing = try? Data(contentsOf: credentialsURL), existing == payload {
            note("credentials already current")
            return true  // current, and usable — not a failure
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
