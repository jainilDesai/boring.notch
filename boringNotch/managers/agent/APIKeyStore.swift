//
//  APIKeyStore.swift
//  boringNotch
//
//  The user's model API key, in their login keychain.
//
//  This is the thing that makes Brow distributable. The agent currently runs on
//  a personal OAuth token mirrored out of the keychain into a plaintext file by
//  a LaunchAgent on a timer, because the Claude Code CLI needed it there. A key
//  the user pastes in and we store properly has no expiry, no mirror, no timer,
//  and no race -- see brow-agent/docs/04-SECURITY.md.
//
//  Never write the key to UserDefaults, a log line, or a settings export. The
//  keychain item is created without kSecAttrSynchronizable, so it stays on this
//  Mac rather than travelling through iCloud.
//

import Foundation
import Security

enum APIKeyStore {

    /// One entry per provider, so switching providers does not overwrite a key
    /// the user may want back.
    enum Provider: String, CaseIterable {
        case anthropic

        var service: String { "com.jainildesai.brow.\(rawValue).apikey" }

        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            }
        }
    }

    // MARK: - Read

    static func key(for provider: Provider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func hasKey(for provider: Provider) -> Bool { key(for: provider) != nil }

    // MARK: - Write

    /// Stores the key, replacing any existing one. Passing nil or blank
    /// deletes it, so clearing the Settings field actually revokes access
    /// rather than leaving a stale key behind.
    @discardableResult
    static func setKey(_ value: String?, for provider: Provider) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return delete(provider) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available after first unlock so the agent still works when the
            // screen is locked, but never leaves this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ provider: Provider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Display

    /// For Settings, so the user can tell which key is stored without the key
    /// being readable over their shoulder or in a screen recording.
    static func redacted(for provider: Provider) -> String? {
        guard let key = key(for: provider) else { return nil }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }
}
