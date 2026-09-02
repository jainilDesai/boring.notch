//
//  AgentRunner.swift
//  BoringNotchXPCHelper
//
//  Runs the Claude CLI on behalf of the sandboxed app.
//
//  This lives in the helper because the app is sandboxed and cannot spawn a
//  real subprocess with useful privileges.
//
//  STAGE B: the agent runs with `--restricted`, which removes Bash and every
//  other command-running tool. It can answer, but it cannot execute anything.
//  That is deliberate — it proves the pipeline before any command can run.
//  Stage C adds `--tools Bash` together with the PreToolUse confirm gate, and
//  the two must land together. Do not add `--tools Bash` here on its own.
//

import Foundation

final class AgentRunner {

    /// Wall-clock ceiling. A voice command that takes longer than this is stuck.
    private static let timeout: TimeInterval = 90

    private let stateQueue = DispatchQueue(label: "BoringNotchXPCHelper.agent.state")
    private var process: Process?
    private var timeoutWorkItem: DispatchWorkItem?

    /// Absolute path — the helper does not inherit a useful PATH.
    private static func resolveCLI() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Scratch working directory. The agent's file tools are confined here.
    private static func workingDirectory() -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Brow/agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let systemPrompt = """
    You are Jarvis, a voice assistant running in the macOS menu bar. The user \
    spoke to you; your reply is shown in a small notch overlay and may be read \
    aloud. \
    Answer in at most two short sentences. No markdown, no lists, no preamble. \
    If you cannot do something, say so plainly in one sentence.
    """

    func run(transcript: String, completion: @escaping (String?, String?) -> Void) {
        // Exactly one reply, whatever happens — a dropped XPC reply block hangs
        // the caller's continuation forever. Owned here so a retry cannot
        // produce a second reply.
        let replied = ReplyOnce(completion)

        // The on-disk token expires; refresh it from the keychain before we
        // waste a launch discovering that.
        if CredentialSync.needsSync() {
            CredentialSync.sync()
        }
        launch(transcript: transcript, allowRetry: true, replied: replied)
    }

    private func launch(transcript: String, allowRetry: Bool, replied: ReplyOnce) {
        guard let cli = Self.resolveCLI() else {
            replied.send(nil, "Couldn't find the claude CLI.")
            return
        }

        stateQueue.async { [weak self] in
            guard let self else {
                replied.send(nil, "Helper went away.")
                return
            }
            self.terminateLocked()

            let process = Process()
            process.executableURL = cli
            process.currentDirectoryURL = Self.workingDirectory()
            process.arguments = [
                "-p", transcript,
                "--output-format", "json",
                "--model", "haiku",
                // No Bash, no code execution, no WebFetch. Stage C revisits this.
                "--restricted",
                "--strict-mcp-config",
                "--append-system-prompt", Self.systemPrompt,
            ]

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = NSHomeDirectory()
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            // USER/LOGNAME are load-bearing: the CLI's credentials live in a
            // keychain item keyed by account name, and without these it reports
            // "Not logged in". An XPC service's launchd environment may not
            // carry them, so set them explicitly.
            environment["USER"] = NSUserName()
            environment["LOGNAME"] = NSUserName()
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            process.terminationHandler = { [weak self] proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                self?.stateQueue.async {
                    self?.timeoutWorkItem?.cancel()
                    self?.timeoutWorkItem = nil
                    self?.process = nil
                }

                if proc.terminationReason == .uncaughtSignal {
                    replied.send(nil, "Cancelled.")
                    return
                }
                let parsed = Self.parse(outData)
                if let text = parsed.text {
                    replied.send(text, nil)
                    return
                }
                // Surface the real reason. The CLI reports failures like
                // "Not logged in" inside the JSON envelope, not on stderr, so
                // preferring stderr here hides the useful message.
                let stderrText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = parsed.error
                    ?? (stderrText?.isEmpty == false ? stderrText : nil)
                    ?? "exit \(proc.terminationStatus), no output"

                // The CLI may refresh its token back into the keychain, leaving
                // our file stale. Re-sync and try once more before giving up.
                if allowRetry, CredentialSync.isAuthError(detail), CredentialSync.sync() {
                    self?.launch(transcript: transcript, allowRetry: false, replied: replied)
                    return
                }
                replied.send(nil, detail)
            }

            do {
                try process.run()
            } catch {
                replied.send(nil, "Couldn't start the agent: \(error.localizedDescription)")
                return
            }
            self.process = process

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.stateQueue.async {
                    if let running = self?.process, running.isRunning {
                        running.terminate()
                    }
                }
                replied.send(nil, "The agent timed out.")
            }
            self.timeoutWorkItem = timeoutItem
            self.stateQueue.asyncAfter(deadline: .now() + Self.timeout, execute: timeoutItem)
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            self?.terminateLocked()
        }
    }

    /// Must be called on `stateQueue`.
    private func terminateLocked() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    /// Pulls the reply out of the CLI's `--output-format json` envelope, or the
    /// reason it failed. Exactly one of the two is non-nil.
    private static func parse(_ data: Data) -> (text: String?, error: String?) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (nil, raw.isEmpty ? nil : "Unexpected output: \(raw.prefix(200))")
        }

        let result = (object["result"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let isError = object["is_error"] as? Bool, isError {
            // e.g. "Not logged in · Please run /login"
            return (nil, result?.isEmpty == false ? result : "The agent reported an error.")
        }
        guard let result, !result.isEmpty else {
            return (nil, "The agent returned an empty reply.")
        }
        return (result, nil)
    }
}

/// Guarantees an XPC reply block is invoked exactly once.
private final class ReplyOnce {
    private let lock = NSLock()
    private var block: ((String?, String?) -> Void)?

    init(_ block: @escaping (String?, String?) -> Void) {
        self.block = block
    }

    func send(_ text: String?, _ error: String?) {
        lock.lock()
        let block = self.block
        self.block = nil
        lock.unlock()
        block?(text, error)
    }
}
