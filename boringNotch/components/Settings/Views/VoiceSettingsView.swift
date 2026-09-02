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
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Voice")
    }
}
