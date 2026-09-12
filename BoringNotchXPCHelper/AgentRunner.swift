//
//  AgentRunner.swift
//  BoringNotchXPCHelper
//
//  Runs the Claude CLI on behalf of the sandboxed app.
//
//  This lives in the helper because the app is sandboxed and cannot spawn a
//  real subprocess with useful privileges.
//
//  The agent runs with `--tools Bash`, so Bash is the ONLY built-in tool it
//  has — no file tools, no WebFetch. Every Bash command is then screened by
//  AgentGate's PreToolUse hook, which denies by default.
//
//  `--tools Bash` and `--settings <gate>` must always be passed together.
//  Bash without the gate is an unguarded shell driven by a microphone.
//
//  `--restricted` was used while the gate was not firing, because the CLI's own
//  refusal of state-changing commands was then the only protection. It is now
//  removed: the hook is confirmed working in real use (deny on a multi-line
//  heredoc, auto-allow on read-only commands, and a confirm dialog the user
//  approved), and `--restricted` reserves permission decisions in a way that
//  stopped mutations reaching the gate at all.
//
//  Removing it costs settings-file isolation, so user settings load again.
//  That is acceptable because a PreToolUse hook runs regardless of any
//  permission rule, which keeps AgentGate authoritative for denials.
//
//  If gate.log ever stops gaining lines for real commands, the gate is not in
//  the path and this flag must go back in until it is.
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
    Answer in at most two short sentences. No markdown, no lists, no preamble.

    You have a Bash tool and can inspect and control this Mac with it. Prefer \
    one short single-line command over several.

    ALWAYS use the tool to find things out. Never answer a question about this \
    Mac — disk space, running processes, files, settings, battery — from memory \
    or inference. If you did not run a command, you do not know the answer.

    NEVER ask the user for permission and never ask "should I proceed". Just \
    call the tool. A separate system screens every command before it runs: safe \
    ones execute immediately, anything that changes state prompts the user to \
    approve, and dangerous ones are refused outright. Gatekeeping is not your \
    job, and asking in text only strands the user with a question they cannot \
    answer.

    If a command is denied or fails, say so plainly in one sentence. Do not \
    guess the answer, do not invent numbers, and do not work around a refusal.
    """

    func run(transcript: String, completion: @escaping (String?, String?) -> Void) {
        // Exactly one reply, whatever happens — a dropped XPC reply block hangs
        // the caller's continuation forever. Owned here so a retry cannot
        // produce a second reply.
        let replied = ReplyOnce(completion)

        // The on-disk token expires; refresh it from the keychain before we
        // waste a launch discovering that.
        // Credentials are owned by the com.jainildesai.brow.credentials
        // LaunchAgent, which runs in the user's Aqua session — the only context
        // that can read the login keychain. This helper cannot, so it does not
        // try: an expired file is simply cleared so it cannot shadow anything,
        // and the agent rewrites it within its refresh interval.
        CredentialSync.removeIfExpired()
        // Rewrite the hook and settings every run so the gate cannot drift from
        // the binary that depends on it.
        AgentGate.install()
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
            // Run through a login shell so the CLI sees the same environment a
            // Terminal session gives it. Spawned directly from this XPC service
            // it cannot reach its keychain credentials and reports "Not logged
            // in"; a fresh terminal session works, so reproduce that context
            // rather than copying secrets out of the keychain to work around it.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.currentDirectoryURL = Self.workingDirectory()
            // Every value is passed through the environment, never interpolated
            // into the command string — the transcript is arbitrary speech and
            // must not be able to become shell syntax.
            process.arguments = ["-l", "-c", """
            exec "$BROW_CLI" -p "$BROW_PROMPT" \
              --output-format json \
              --model haiku \
              --tools Bash \
              --permission-mode acceptEdits \
              --settings "$BROW_SETTINGS" \
              --strict-mcp-config \
              --append-system-prompt "$BROW_SYSTEM_PROMPT"
            """]

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = NSHomeDirectory()
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            // USER/LOGNAME are load-bearing: the CLI's credentials live in a
            // keychain item keyed by account name, and without these it reports
            // "Not logged in". An XPC service's launchd environment may not
            // carry them, so set them explicitly.
            environment["USER"] = NSUserName()
            environment["LOGNAME"] = NSUserName()
            environment["BROW_CLI"] = cli.path
            environment["BROW_PROMPT"] = transcript
            environment["BROW_SETTINGS"] = AgentGate.settingsURL.path
            environment["BROW_SYSTEM_PROMPT"] = Self.systemPrompt
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

    /// Finds the CLI's JSON envelope in the output.
    ///
    /// Running through a login shell means `.zprofile`/`.zshrc` may print
    /// banners ahead of the JSON, so the whole buffer is not necessarily valid
    /// JSON. Try it first, then fall back to scanning lines from the end.
    private static func envelope(in data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let lineData = trimmed.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               object["result"] != nil || object["is_error"] != nil {
                return object
            }
        }
        return nil
    }

    /// Pulls the reply out of the CLI's `--output-format json` envelope, or the
    /// reason it failed. Exactly one of the two is non-nil.
    private static func parse(_ data: Data) -> (text: String?, error: String?) {
        guard let object = envelope(in: data) else {
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
