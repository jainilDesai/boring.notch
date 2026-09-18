//
//  ModelCatalog.swift
//  boringNotch
//
//  Asks a provider what models it has, so the Settings picker lists what is
//  actually available today rather than what was true when this shipped.
//
//  Every OpenAI-compatible service exposes GET {baseURL}/models, so one code
//  path populates the picker for OpenRouter, Gemini, OpenAI and a local Ollama
//  alike. OpenRouter goes further and reports `supported_parameters`, which
//  lets the list be filtered to models that can actually call tools -- the
//  agent is useless without that, and a picker offering a model that silently
//  cannot use tools is a trap.
//

import Foundation

struct CatalogModel: Identifiable, Hashable {
    let id: String
    let name: String
    /// nil when the provider does not say. Absence of evidence, not absence of
    /// support -- so a nil is shown rather than hidden.
    let supportsTools: Bool?

    var label: String { name.isEmpty ? id : name }
}

enum ModelCatalog {

    /// Fetches the model list. Throws only for problems the user can act on.
    static func models(baseURL: URL, apiKey: String?) async throws -> [CatalogModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 20
        // OpenRouter serves this list unauthenticated; OpenAI and Gemini do not.
        // Send the key when there is one and let the server decide.
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, message: "")
        }
        return parse(data)
    }

    /// Separate from fetching so the shape can be tested without a network.
    static func parse(_ data: Data) -> [CatalogModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let supported = entry["supported_parameters"] as? [String]
            return CatalogModel(
                id: id,
                name: entry["name"] as? String ?? id,
                supportsTools: supported.map { $0.contains("tools") })
        }
    }

    /// What the picker should show: models known to support tools, plus those
    /// that did not say, sorted so the familiar names surface first.
    static func usable(_ models: [CatalogModel]) -> [CatalogModel] {
        models
            .filter { $0.supportsTools != false }
            .sorted { $0.id < $1.id }
    }
}
