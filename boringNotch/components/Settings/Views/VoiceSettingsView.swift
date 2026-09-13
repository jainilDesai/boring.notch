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

    /// What the user is typing. Never persisted here -- it goes to the keychain
    /// on Save and this is cleared, so the key is not sitting in view state.
    @State private var apiKeyField = ""
    /// Redacted, so the field shows which key is stored without putting it on
    /// screen during a screen share.
    @State private var storedKey = APIKeyStore.redacted(for: .anthropic)

    /// Offered in the picker, newest first. A field would let someone paste a
    /// model that does not exist and find out by being told the service is
    /// having trouble; these are known to work.
    private static let models: [(id: String, label: String)] = [
        ("claude-haiku-4-5", "Haiku 4.5 — fastest"),
        ("claude-sonnet-5", "Sonnet 5 — balanced"),
        ("claude-opus-5", "Opus 5 — most capable"),
    ]

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

                if agentBackend == .anthropicAPI {
                    HStack {
                        SecureField("sk-ant-…", text: $apiKeyField)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            APIKeyStore.setKey(apiKeyField, for: .anthropic)
                            apiKeyField = ""
                            storedKey = APIKeyStore.redacted(for: .anthropic)
                        }
                        .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let storedKey {
                        LabeledContent("Stored key") {
                            HStack(spacing: 8) {
                                Text(storedKey).font(.system(.body, design: .monospaced))
                                Button("Remove") {
                                    APIKeyStore.delete(.anthropic)
                                    self.storedKey = nil
                                }
                            }
                        }
                    }

                    Picker("Model", selection: $agentModel) {
                        ForEach(Self.models, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                }
            } header: {
                Text("Agent")
            } footer: {
                Text(agentBackend == .anthropicAPI
                     ? "Your key is stored in the login keychain on this Mac and never leaves it. Haiku answers fastest, which is usually what you want from a notch; Opus thinks harder and takes longer."
                     : "The Claude Code CLI answers as whoever installed it, so it only works on this Mac. Switch to an API key to use Brow anywhere.")
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
    }
}
