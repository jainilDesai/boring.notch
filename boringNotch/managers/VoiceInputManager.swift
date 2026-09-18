//
//  VoiceInputManager.swift
//  boringNotch
//
//  Push-to-talk voice capture. Holds the voice shortcut to record from the
//  microphone, transcribes on-device with the macOS 26 Speech framework
//  (SpeechAnalyzer + SpeechTranscriber), and publishes the transcript.
//
//  Nothing here acts on the transcript yet — that is the agent step.
//

import AVFoundation
import Combine
import Defaults
import Foundation
import Speech

// MARK: - State

/// Published session state. Deliberately free of any macOS 26 type so views can
/// observe it without an availability gate of their own.
enum VoiceSessionState: Equatable {
    /// Nothing happening; the notch shows its normal content.
    case idle
    /// Permission checks, locale asset install, model load.
    case preparing(detail: String)
    /// Recording. `partial` is the live volatile transcript, possibly empty.
    case listening(partial: String)
    /// Audio finished, waiting on the last results to finalize.
    case transcribing
    /// Handed to the agent; waiting on a reply.
    case thinking(String)
    /// Heard, but nothing acted on it.
    case result(String)
    /// Heard and executed. Carries a short summary of what was done.
    case acted(String)
    /// The agent replied. Carries its answer.
    case answered(String)
    case failed(String)

    var isActive: Bool { self != .idle }
}

/// Ungated observable holder for `VoiceSessionState`.
///
/// `VoiceInputManager` needs `@available(macOS 26, *)`, and a SwiftUI view cannot
/// hold a stored property of an availability-gated type. Views observe this instead.
@MainActor
final class VoiceSessionStore: ObservableObject {
    static let shared = VoiceSessionStore()
    @Published fileprivate(set) var state: VoiceSessionState = .idle
    private init() {}
}

// MARK: - Manager

@available(macOS 26.0, *)
@MainActor
final class VoiceInputManager {
    static let shared = VoiceInputManager()

    /// Presses shorter than this are treated as a mis-tap and discarded.
    private static let minimumRecordingDuration: TimeInterval = 0.25
    /// How long a finished transcript stays on screen before the notch returns to normal.
    private static let resultLingerDuration: Duration = .seconds(4)
    /// Agent replies are whole sentences and often arrive after a wait, so they
    /// need longer on screen than "Volume 40%".
    private static let answerLingerDuration: Duration = .seconds(10)

    private let store = VoiceSessionStore.shared

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var startedAt: Date?
    private var finalizedText = ""
    private var volatileText = ""
    /// Tracks the `SharingStateManager` balance so it is released exactly once.
    private var holdsNotchOpen = false
    private var isRecording = false
    /// True once the session actually reached the listening state, so a failed
    /// session can say whether it was too-early release or genuine silence.
    private var didStartListening = false

    private init() {}

    var isAvailable: Bool { SpeechTranscriber.isAvailable }

    // MARK: Entry points

    /// Called on shortcut key-down.
    func beginListening() {
        guard Defaults[.voiceAgentEnabled] else { return }
        guard !isRecording, sessionTask == nil else { return }

        resetTask?.cancel()
        resetTask = nil

        isRecording = true
        didStartListening = false
        finalizedText = ""
        volatileText = ""
        startedAt = Date()
        holdNotchOpen()

        sessionTask = Task { [weak self] in
            await self?.startSession()
        }
    }

    /// Called on shortcut key-up.
    func endListening() {
        guard isRecording else { return }
        isRecording = false

        let heldFor = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        Task { [weak self] in
            guard let self else { return }
            // Let setup finish before tearing it down, or we race the engine start.
            await self.sessionTask?.value
            self.sessionTask = nil

            if heldFor < Self.minimumRecordingDuration {
                await self.teardownAudio()
                await self.cancelAnalysis()
                self.store.state = .idle
                self.releaseNotch()
                return
            }
            await self.finishSession()
        }
    }

    // MARK: Session

    private func startSession() async {
        do {
            store.state = .preparing(detail: "Checking microphone…")
            guard await Self.requestMicrophoneAccess() else {
                fail("Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone.")
                return
            }

            guard SpeechTranscriber.isAvailable else {
                fail("On-device speech recognition is unavailable on this Mac.")
                return
            }

            guard let locale = await Self.resolveLocale() else {
                fail("No supported speech locale for \(Locale.current.identifier).")
                return
            }

            // `.progressiveTranscription` reports volatile results, which is what
            // drives the live partial text in the overlay.
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            self.transcriber = transcriber

            // First run for a locale downloads a system-managed asset. It is shared
            // across apps, so this is usually a no-op after the first time.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                store.state = .preparing(detail: "Downloading speech model…")
                try await request.downloadAndInstall()
            }

            guard isRecording else { return }  // released the key during setup

            store.state = .preparing(detail: "Starting…")

            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                // `.processLifetime` keeps the model warm so repeat commands are fast.
                options: .init(priority: .userInitiated, modelRetention: .processLifetime)
            )
            self.analyzer = analyzer

            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation

            consumeResults(from: transcriber)

            try await analyzer.start(inputSequence: stream)
            try startAudioEngine()

            guard isRecording else { return }
            didStartListening = true
            store.state = .listening(partial: "")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finishSession() async {
        store.state = .transcribing

        await teardownAudio()

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Finalization failing still leaves whatever text we already committed.
            NSLog("[voice] finalize failed: \(error.localizedDescription)")
        }

        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil

        // Fall back to the volatile (not yet finalized) text: a short utterance
        // released quickly can end the stream before a final result arrives,
        // and throwing that away loses a perfectly good transcript.
        var text = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.isEmpty {
            // Distinguish "released before the recogniser was ready" from
            // "listened, heard nothing" — they have different fixes.
            if didStartListening {
                VoiceAuditLog.record(event: "empty_transcript")
                store.state = .failed("Didn't catch that.")
            } else {
                VoiceAuditLog.record(event: "released_before_ready")
                store.state = .failed("Still starting up — hold the shortcut a moment longer.")
            }
        } else if let command = CustomCommandStore.shared.match(text) {
            // User-defined commands win over built-ins, so a user can override
            // "open youtube" with their own version.
            await runCustomCommand(command, transcript: text)
        } else if let action = LocalIntentMatcher.match(text) {
            // Fast path: no network, no shell. Anything the matcher declines
            // falls through to the agent.
            let outcome = await ActionExecutor.run(action)
            VoiceAuditLog.record(event: outcome.succeeded ? "acted" : "action_failed", fields: [
                "transcript": text,
                "action": String(describing: action),
                "outcome": outcome.message,
            ])
            store.state = outcome.succeeded ? .acted(outcome.message) : .failed(outcome.message)
        } else {
            // No local match — hand it to the agent. It runs with --restricted
            // in the helper, so it can answer but cannot execute anything.
            VoiceAuditLog.record(event: "no_match", fields: ["transcript": text])
            await runAgent(on: text)
        }
        scheduleReset()
    }

    /// Runs a user-defined command, confirming first when it asks to.
    private func runCustomCommand(_ command: CustomCommand, transcript: String) async {
        if command.requiresConfirmation {
            let summary = command.steps.map(\.summary).joined(separator: "\n")
            guard await ConfirmPrompt.ask(
                title: command.name.isEmpty ? "Run this command?" : "Run \"\(command.name)\"?",
                detail: summary
            ) else {
                VoiceAuditLog.record(event: "custom_declined", fields: [
                    "transcript": transcript, "command": command.name,
                ])
                store.state = .failed("Cancelled")
                return
            }
        }

        VoiceAuditLog.record(event: "custom_command", fields: [
            "transcript": transcript,
            "command": command.name,
            "steps": "\(command.steps.count)",
        ])

        let outcome = await CustomCommandRunner.run(command)
        store.state = outcome.succeeded ? .acted(outcome.message) : .failed(outcome.message)
    }

    /// Sends a transcript the matcher declined to whichever agent back end is
    /// configured.
    private func runAgent(on text: String) async {
        store.state = .thinking(text)
        let started = Date()
        let backend = Defaults[.agentBackend]
        let outcome: Result<String, AgentCommandError>
        if backend == .claudeCLI {
            outcome = await XPCHelperClient.shared.runAgentCommand(text)
        } else if let provider = AgentProviderFactory.make(
            backend: backend,
            model: Defaults[.agentModel],
            effort: Defaults[.agentEffort],
            customBaseURL: Defaults[.agentBaseURL]
        ) {
            outcome = await runOwnedLoop(on: text, provider: provider)
        } else {
            // Configured to use an API back end that is not set up. Say which
            // thing is missing rather than failing as "no answer".
            outcome = .failure(.message(
                backend == .custom
                    ? "Set a server URL for \(backend.displayName) in Settings."
                    : "\(backend.displayName) isn't set up. Add a key in Settings."))
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

        switch outcome {
        case let .success(reply):
            VoiceAuditLog.record(event: "agent_replied", fields: [
                "transcript": text, "reply": reply, "seconds": elapsed,
            ])
            store.state = .answered(reply)
        case let .failure(error):
            VoiceAuditLog.record(event: "agent_failed", fields: [
                "transcript": text, "error": error.text, "seconds": elapsed,
            ])
            store.state = .failed(error.text)
        }
    }

    /// The agent loop Brow owns, talking to the API with the user's own key.
    ///
    /// Typed actions run here in the app, where the managers live. Only
    /// run_shell crosses to the helper, which screens it with the same gate
    /// that screens the CLI path.
    private func runOwnedLoop(
        on text: String,
        provider: ModelProvider
    ) async -> Result<String, AgentCommandError> {
        let loop = AgentLoop(
            provider: provider,
            runAction: { action in
                let outcome = await ActionExecutor.run(action)
                return outcome.succeeded ? .ok(outcome.message) : .failed(outcome.message)
            },
            runShell: { command in
                switch await XPCHelperClient.shared.runGatedShellCommand(command) {
                case let .success(output):
                    // An empty result reads as a broken tool to the model, and
                    // plenty of commands legitimately print nothing.
                    return .ok(output.isEmpty ? "(no output)" : output)
                case let .failure(error):
                    return .failed(error.text)
                }
            })

        // Say what it is doing rather than spinning: the agent path runs for
        // seconds, and silence is indistinguishable from a hang.
        loop.onProgress = { [weak self] note in
            Task { @MainActor in self?.store.state = .thinking(note) }
        }

        do {
            let outcome = try await loop.run(transcript: text, system: Self.agentSystemPrompt)
            VoiceAuditLog.record(event: "agent_tools", fields: [
                "transcript": text,
                "tools": outcome.toolsUsed.joined(separator: ","),
                "turn_limit": outcome.stoppedAtTurnLimit ? "yes" : "no",
            ])
            guard !outcome.text.isEmpty else { return .failure(.message("No answer came back.")) }
            return .success(outcome.text)
        } catch is CancellationError {
            return .failure(.message("Cancelled"))
        } catch {
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            return .failure(.message(message))
        }
    }

    /// Kept beside the loop rather than in the helper, because the helper's
    /// copy describes the CLI's raw Bash tool and this one describes typed
    /// tools. They are different surfaces and should not be one string.
    private static let agentSystemPrompt = """
    You are Jarvis, a voice assistant running in the macOS menu bar. The user \
    spoke to you; your reply is shown in a small notch overlay and may be read \
    aloud. Answer in at most two short sentences. No markdown, no lists, no \
    preamble.

    Use the tools to find things out and to act. Never answer a question about \
    this Mac from memory or inference -- if you did not call a tool, you do not \
    know. Prefer the typed tools over run_shell whenever one fits.

    Never ask for permission and never ask whether you should proceed. A \
    separate system screens every shell command: read-only ones run \
    immediately, anything that changes state asks the user, and dangerous ones \
    are refused. Gatekeeping is not your job, and asking in text strands the \
    user with a question they cannot answer.

    If a tool is denied or fails, say so plainly in one sentence. Do not guess, \
    do not invent numbers, and do not work around a refusal.
    """

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    if self.isRecording {
                        let combined = (self.finalizedText + self.volatileText)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.store.state = .listening(partial: combined)
                    }
                }
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    // MARK: Audio

    private func startAudioEngine() throws {
        guard let analyzerFormat else {
            throw VoiceInputError.noCompatibleAudioFormat
        }

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw VoiceInputError.noInputDevice
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw VoiceInputError.noCompatibleAudioFormat
        }
        self.converter = converter

        // Capture locals: the tap runs on a realtime audio thread and must not
        // touch main-actor state.
        guard let continuation = inputContinuation else {
            throw VoiceInputError.noCompatibleAudioFormat
        }
        let outputFormat = analyzerFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: outputFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Resamples a tap buffer into the format the analyzer asked for.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func teardownAudio() async {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        converter = nil
        inputContinuation?.finish()
        inputContinuation = nil
    }

    private func cancelAnalysis() async {
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    // MARK: Helpers

    private func fail(_ message: String) {
        NSLog("[voice] failed: \(message)")
        VoiceAuditLog.record(event: "session_failed", fields: ["reason": message])
        isRecording = false
        store.state = .failed(message)
        Task { [weak self] in
            await self?.teardownAudio()
            await self?.cancelAnalysis()
        }
        scheduleReset()
    }

    /// Returns the notch to normal after the result has been on screen a moment.
    private func scheduleReset() {
        // An agent reply is a sentence to read, and arrives after several
        // seconds of waiting — the short linger used for "Volume 40%" is not
        // long enough to catch it.
        let linger: Duration
        if case .answered = store.state {
            linger = Self.answerLingerDuration
        } else {
            linger = Self.resultLingerDuration
        }

        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled, let self else { return }
            self.store.state = .idle
            self.releaseNotch()
        }
    }

    /// Keeps the notch from auto-closing mid-session. Balanced by `releaseNotch`.
    private func holdNotchOpen() {
        guard !holdsNotchOpen else { return }
        holdsNotchOpen = true
        SharingStateManager.shared.beginInteraction()
    }

    private func releaseNotch() {
        guard holdsNotchOpen else { return }
        holdsNotchOpen = false
        SharingStateManager.shared.endInteraction()
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Prefers the user's own locale, falling back to any installed one.
    private static func resolveLocale() async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        if let installed = await SpeechTranscriber.installedLocales.first {
            return installed
        }
        return await SpeechTranscriber.supportedLocales.first
    }
}

// MARK: - Support

enum VoiceInputError: LocalizedError {
    case noCompatibleAudioFormat
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudioFormat:
            return "No audio format compatible with the speech transcriber."
        case .noInputDevice:
            return "No microphone input device is available."
        }
    }
}
