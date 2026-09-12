//
//  UserCommandRunner.swift
//  BoringNotchXPCHelper
//
//  Runs a shell command authored by the user in Settings > Commands.
//
//  Separate from AgentRunner on purpose. AgentRunner executes what a language
//  model decided to run, so every command it produces is screened by AgentGate.
//  This path executes what the user typed into a settings field themselves, and
//  the app has already confirmed with them when the command contains a
//  shell/AppleScript/Shortcut step.
//
//  It still runs in the unsandboxed helper because the app cannot spawn a shell.
//

import Foundation

enum UserCommandRunner {

    /// User commands are meant to be quick actions, not long jobs.
    private static let timeout: TimeInterval = 30
    private static let maxOutputBytes = 8_000

    static func run(command: String, completion: @escaping (String?, String?) -> Void) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(nil, "Empty command")
            return
        }

        let process = Process()
        // A login shell so user commands see the PATH they expect from Terminal.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", trimmed]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        // Guarantee exactly one reply: a dropped XPC reply block hangs the app.
        let lock = NSLock()
        var replied = false
        func finish(_ text: String?, _ error: String?) {
            lock.lock()
            let alreadyReplied = replied
            replied = true
            lock.unlock()
            guard !alreadyReplied else { return }
            completion(text, error)
        }

        var timeoutItem: DispatchWorkItem?

        process.terminationHandler = { proc in
            timeoutItem?.cancel()
            let data = output.fileHandleForReading.readDataToEndOfFile().prefix(maxOutputBytes)
            let text = String(data: Data(data), encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                finish(text, nil)
            } else {
                let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(nil, detail.isEmpty
                    ? "Command failed (exit \(proc.terminationStatus))"
                    : String(detail.prefix(300)))
            }
        }

        do {
            try process.run()
        } catch {
            finish(nil, "Couldn't run command: \(error.localizedDescription)")
            return
        }

        let item = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            finish(nil, "Command timed out after \(Int(timeout))s")
        }
        timeoutItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }
}
