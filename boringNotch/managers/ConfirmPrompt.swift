//
//  ConfirmPrompt.swift
//  boringNotch
//
//  Blocking yes/no prompt for actions a voice command wants to take.
//
//  Drawn by the app rather than the XPC helper: the app is a normal GUI process
//  and can reliably put a window on screen. Approval is a click or a keypress —
//  never speech, because anything audible near the microphone could otherwise
//  approve its own command.
//

import AppKit

@MainActor
enum ConfirmPrompt {

    /// Shows a modal and returns true only if the user explicitly approves.
    /// Any other outcome — cancel, dismissal, unexpected response — is a no.
    static func ask(title: String, detail: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail.isEmpty ? "This will run now." : detail
        alert.alertStyle = .warning
        // First button is the default; make the safe choice the default one.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Run")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
