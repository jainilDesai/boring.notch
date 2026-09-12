//
//  CommandsSettingsView.swift
//  boringNotch
//
//  Editor for user-defined voice commands: trigger phrases plus an ordered list
//  of steps.
//

import Defaults
import SwiftUI

struct CommandsSettings: View {
    @StateObject private var store = CustomCommandStore.shared
    @State private var editing: CustomCommand?
    @State private var isCreating = false

    var body: some View {
        Form {
            Section {
                if store.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No commands yet")
                            .foregroundStyle(.secondary)
                        Text("Add one to say things like \"open my portfolio\" or \"kaboom\" and have Brow run whatever you want — open a site, run a shell command, trigger a Shortcut, or several in a row.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(store.commands) { command in
                        CommandRow(command: command) {
                            editing = command
                        }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                    .onDelete { indexes in
                        for index in indexes { store.delete(store.commands[index]) }
                    }
                }
            } header: {
                HStack {
                    Text("Your commands")
                    Spacer()
                    Button {
                        editing = CustomCommand()
                        isCreating = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            } footer: {
                Text("Your commands are checked before the built-in ones, so you can override them. Triggers must match what you say exactly, after punctuation and casing are ignored.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Commands")
        .sheet(item: $editing) { command in
            CommandEditor(command: command, isNew: isCreating) { saved in
                if isCreating { store.add(saved) } else { store.update(saved) }
                isCreating = false
            } onCancel: {
                isCreating = false
            }
        }
    }
}

// MARK: - Row

private struct CommandRow: View {
    let command: CustomCommand
    let onEdit: () -> Void

    @StateObject private var store = CustomCommandStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { command.isEnabled },
                set: { newValue in
                    var copy = command
                    copy.isEnabled = newValue
                    store.update(copy)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.name.isEmpty ? "Untitled" : command.name)
                        .fontWeight(.medium)
                    if command.requiresConfirmation {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Asks before running")
                    }
                    if command.runsArbitraryCode {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Runs code")
                    }
                }
                Text(command.phrases.filter { !$0.isEmpty }.map { "“\($0)”" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(command.steps.map(\.summary).joined(separator: " → "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
            Button("Edit", action: onEdit)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .opacity(command.isEnabled ? 1 : 0.5)
    }
}

// MARK: - Editor

private struct CommandEditor: View {
    @State var command: CustomCommand
    let isNew: Bool
    let onSave: (CustomCommand) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Phrases are edited as free text, one per line.
    @State private var phrasesText: String = ""

    private var isValid: Bool {
        !command.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !parsedPhrases.isEmpty
            && !command.steps.isEmpty
    }

    private var parsedPhrases: [String] {
        phrasesText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New command" : "Edit command").font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Name") {
                        TextField("Kaboom", text: $command.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trigger phrases").font(.subheadline)
                        Text("One per line. Say any of them to run this command.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $phrasesText)
                            .font(.body)
                            .frame(minHeight: 60, maxHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Steps").font(.subheadline)
                            Spacer()
                            Button {
                                command.steps.append(CommandStep())
                            } label: {
                                Label("Add step", systemImage: "plus")
                            }
                            .buttonStyle(.borderless)
                        }
                        Text("Run in order, stopping if one fails.")
                            .font(.caption).foregroundStyle(.secondary)

                        ForEach($command.steps) { $step in
                            StepEditor(step: $step) {
                                command.steps.removeAll { $0.id == step.id }
                            }
                        }
                    }

                    Toggle(isOn: $command.requiresConfirmation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask before running")
                            Text("Recommended for anything that runs code or changes files — speech recognition mishears, and a trigger phrase can fire by accident.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                if command.runsArbitraryCode && !command.requiresConfirmation {
                    Label("This runs code without asking first", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { onCancel(); dismiss() }
                Button("Save") {
                    command.phrases = parsedPhrases
                    onSave(command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
        .onAppear {
            phrasesText = command.phrases.joined(separator: "\n")
            // Default new powerful commands to confirming.
            if isNew { command.requiresConfirmation = false }
        }
        .onChange(of: command.steps) {
            // Adding a code-running step opts the command into confirming —
            // for EDITED commands too, not just new ones. Gating this on isNew
            // meant adding a shell step to an existing command left it firing
            // unconfirmed, on nothing but ambient audio.
            if command.runsArbitraryCode {
                command.requiresConfirmation = true
            }
        }
    }
}

// MARK: - Step editor

private struct StepEditor: View {
    @Binding var step: CommandStep
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $step.kind) {
                    ForEach(CommandStep.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            if let label = step.kind.valueLabel {
                if step.kind == .shell || step.kind == .appleScript {
                    TextEditor(text: $step.value)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 54, maxHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                } else {
                    TextField(label, text: $step.value)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let label = step.kind.numberLabel {
                HStack {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("", value: $step.number, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }
}
