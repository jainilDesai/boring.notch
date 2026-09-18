//
//  AgentProviderFactory.swift
//  boringNotch
//
//  Turns the Settings values into a provider.
//
//  Its own file because ModelProvider.swift must keep compiling against nothing
//  but Foundation -- that is what lets the agent be tested standalone and moved
//  to the brow-agent package in roadmap item 5. This file is where the app's
//  dependencies (Defaults-backed AgentBackend, the keychain, the concrete
//  providers) are allowed to meet the protocol, and nowhere else.
//
//  Putting the factory in ModelProvider.swift broke that within minutes of the
//  rule being written down; the standalone suite caught it on the next run.
//

import Foundation

enum AgentProviderFactory {

    /// The provider for a back end, or nil when that back end is not an API
    /// one (the CLI) or is not configured enough to try.
    ///
    /// One place decides this. The alternative -- a switch at the call site --
    /// is how a new back end ends up working in Settings and nowhere else.
    static func make(
        backend: AgentBackend,
        model: String,
        effort: String,
        customBaseURL: String
    ) -> ModelProvider? {
        switch backend {
        case .claudeCLI:
            return nil

        case .anthropic:
            return AnthropicProvider(
                model: model,
                effort: effort,
                apiKey: { APIKeyStore.key(for: .anthropic) })

        case .openRouter, .gemini:
            guard let url = backend.baseURL, let keyProvider = backend.keyProvider else { return nil }
            return OpenAICompatibleProvider(
                name: backend.displayName,
                baseURL: url,
                model: model,
                apiKey: { APIKeyStore.key(for: keyProvider) })

        case .custom:
            // A blank or unparseable URL means the user has not finished
            // setting it up. Returning nil produces "no API key set", which is
            // the wrong message -- so the caller checks this first.
            let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return OpenAICompatibleProvider(
                name: "Custom",
                baseURL: url,
                model: model,
                apiKey: { APIKeyStore.key(for: .custom) })
        }
    }
}
