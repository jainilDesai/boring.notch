//
//  VoiceSettingsView.swift
//  boringNotch
//
//  Settings for push-to-talk voice input.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import Speech
import SwiftUI

struct VoiceSettings: View {
    @Default(.voiceAgentEnabled) var voiceAgentEnabled: Bool
    @Default(.agentBackend) var agentBackend: AgentBackend
    @Default(.agentModel) var agentModel: String
    @Default(.agentBaseURL) var agentBaseURL: String

    /// What the user is typing. Never persisted here -- it goes to the keychain
    /// on Save and this is cleared, so the key is not sitting in view state.
    @State private var apiKeyField = ""
    /// Redacted, so the field shows which key is stored without putting it on
    /// screen during a screen share.
    @State private var storedKey: String?

    /// Fetched from the back end rather than hardcoded, so the list is what is
    /// actually available today. Empty until loaded; the current model is always
    /// offered so the picker cannot silently change what you chose.
    @State private var catalog: [CatalogModel] = []
    @State private var catalogError: String?
    @State private var isLoadingCatalog = false

    /// The Speech framework transcriber used here is macOS 26 only.
    private var isSupported: Bool {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    private var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .voiceAgentEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable voice input")
                        Group {
                            if isSupported {
                                Text("Hold the voice shortcut to record. Speech is transcribed on-device and never leaves your Mac.")
                            } else {
                                Text("Requires macOS 26 or later with on-device speech recognition available.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(!isSupported)
            } header: {
                Text("Voice")
            }

            Section {
                KeyboardShortcuts.Recorder("Push to talk:", name: .voiceCommand)
            } footer: {
                Text("Hold the shortcut while speaking, then release. The transcript appears in the notch.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                LabeledContent("Microphone access") {
                    switch microphoneStatus {
                    case .authorized:
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .notDetermined:
                        // macOS only lists the app under Privacy > Microphone once it
                        // has actually asked, so sending the user there now is a dead end.
                        Text("You'll be asked the first time you use the shortcut.")
                            .foregroundStyle(.secondary)
                    default:
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } footer: {
                Text("The first time you use the shortcut, macOS may download a speech model for your language. That happens once and is shared with other apps.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Picker("Answers come from", selection: $agentBackend) {
                    ForEach(AgentBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .onChange(of: agentBackend) { _, backend in
                    // Each back end names its models differently, so a model
                    // carried across from the last one would 404.
                    agentModel = backend.defaultModel
                    reload(for: backend)
                }

                if agentBackend != .claudeCLI {
                    if agentBackend == .custom {
                        TextField("https://localhost:11434/v1", text: $agentBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { reload(for: agentBackend) }
                    }

                    HStack {
                        SecureField("API key", text: $apiKeyField)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            if let provider = agentBackend.keyProvider {
                                APIKeyStore.setKey(apiKeyField, for: provider)
                                apiKeyField = ""
                                storedKey = APIKeyStore.redacted(for: provider)
                                reload(for: agentBackend)
                            }
                        }
                        .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let storedKey {
                        LabeledContent("Stored key") {
                            HStack(spacing: 8) {
                                Text(storedKey).font(.system(.body, design: .monospaced))
                                Button("Remove") {
                                    if let provider = agentBackend.keyProvider {
                                        APIKeyStore.delete(provider)
                                    }
                                    self.storedKey = nil
                                }
                            }
                        }
                    } else if let url = agentBackend.signupURL {
                        LabeledContent("No key yet") {
                            Link("Get one", destination: url)
                        }
                    }

                    HStack {
                        if catalog.isEmpty {
                            // No list yet: let them type rather than trapping
                            // them behind a failed fetch.
                            TextField("Model", text: $agentModel)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("Model", selection: $agentModel) {
                                if !catalog.contains(where: { $0.id == agentModel }) {
                                    Text(agentModel).tag(agentModel)
                                }
                                ForEach(catalog) { model in
                                    Text(model.label).tag(model.id)
                                }
                            }
                        }
                        Button {
                            reload(for: agentBackend)
                        } label: {
                            if isLoadingCatalog {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isLoadingCatalog)
                        .help("Fetch the model list from this provider")
                    }

                    if let catalogError {
                        Text(catalogError).font(.caption).foregroundStyle(.secondary)
                    } else if !catalog.isEmpty {
                        Text("\(catalog.count) models that support tools")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Agent")
            } footer: {
                Text(footerText)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                LabeledContent("Activity log") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([VoiceAuditLog.fileURL])
                    }
                }
            } footer: {
                Text("Every voice session is recorded locally: what was heard, what it matched, and what happened.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Voice")
        .onAppear {
            storedKey = agentBackend.keyProvider.flatMap { APIKeyStore.redacted(for: $0) }
            if agentBackend != .claudeCLI { reload(for: agentBackend) }
        }
    }

    private var footerText: String {
        switch agentBackend {
        case .claudeCLI:
            return "The Claude Code CLI answers as whoever installed it, so it only works on this Mac. Pick any other option to use Brow with your own key."
        case .openRouter:
            return "One key, every major model — Claude, Gemini, GPT and more. Your key is stored in the login keychain on this Mac. Requests are routed through OpenRouter."
        case .gemini:
            return "Uses Gemini's OpenAI-compatible endpoint. Your key is stored in the login keychain on this Mac and goes straight to Google."
        case .anthropic:
            return "Your key is stored in the login keychain on this Mac. Haiku answers fastest, which is usually what you want from a notch; Opus thinks harder and takes longer."
        case .custom:
            return "Any server that speaks the OpenAI chat-completions API, including a local Ollama or LM Studio. Only models that support tool calling will work."
        }
    }

    /// Asks the back end what models it has. Failure is shown, not thrown: a
    /// provider with no /models endpoint is usable, you just have to type the
    /// name yourself.
    private func reload(for backend: AgentBackend) {
        guard backend != .claudeCLI else {
            catalog = []; catalogError = nil; return
        }
        let base: URL? = backend == .custom
            ? URL(string: agentBaseURL.trimmingCharacters(in: .whitespaces))
            : backend.baseURL
        guard let base, base.scheme != nil else {
            catalog = []
            catalogError = backend == .custom ? "Enter a server URL." : nil
            return
        }

        let key = backend.keyProvider.flatMap { APIKeyStore.key(for: $0) }
        isLoadingCatalog = true
        catalogError = nil
        Task {
            do {
                let found = try await ModelCatalog.models(baseURL: base, apiKey: key)
                catalog = ModelCatalog.usable(found)
                if catalog.isEmpty { catalogError = "That provider returned no models." }
            } catch {
                catalog = []
                catalogError = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            }
            isLoadingCatalog = false
        }
    }
}
