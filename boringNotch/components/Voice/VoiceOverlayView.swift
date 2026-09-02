//
//  VoiceOverlayView.swift
//  boringNotch
//
//  Transient panel shown in the open notch while a voice session is running.
//  Replaces the normal notch content for the duration of the session, then
//  disappears — it is not a tab.
//

import SwiftUI

struct VoiceOverlayView: View {
    @ObservedObject private var store = VoiceSessionStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                // The notch is a fixed ~640x140 box, so long transcripts scroll
                // rather than growing the window.
                ScrollView(.vertical, showsIndicators: false) {
                    Text(body_)
                        .font(.system(size: 15))
                        .foregroundStyle(bodyColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusIcon: some View {
        switch store.state {
        case .idle:
            EmptyView()
        case .preparing, .transcribing, .thinking:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
        case .listening:
            PulsingDot()
        case .result:
            Image(systemName: "text.quote")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        case .acted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.green)
        case .answered:
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(.purple)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch store.state {
        case .idle: return ""
        case .preparing: return "Getting ready"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Thinking…"
        case .result: return "Heard"
        case .acted: return "Done"
        case .answered: return "Jarvis"
        case .failed: return "Voice input failed"
        }
    }

    /// Trailing underscore: `body` is taken by `View`.
    private var body_: String {
        switch store.state {
        case .idle:
            return ""
        case let .preparing(detail):
            return detail
        case let .listening(partial):
            return partial.isEmpty ? "Speak now, then release the shortcut." : partial
        case .transcribing:
            return ""
        case let .thinking(text):
            return text
        case let .result(text):
            return text
        case let .acted(summary):
            return summary
        case let .answered(reply):
            return reply
        case let .failed(message):
            return message
        }
    }

    private var bodyColor: Color {
        switch store.state {
        case .result: return .white
        case .acted: return .white
        case .answered: return .white
        case .thinking: return .gray
        case .failed: return .orange
        case let .listening(partial): return partial.isEmpty ? .gray : .white
        default: return .gray
        }
    }
}

/// Recording indicator.
private struct PulsingDot: View {
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 14, height: 14)
            .scaleEffect(animating ? 1.0 : 0.6)
            .opacity(animating ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: animating)
            .onAppear { animating = true }
    }
}
