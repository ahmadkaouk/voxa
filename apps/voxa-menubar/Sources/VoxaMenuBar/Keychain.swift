import Foundation
import Security

enum KeychainError: LocalizedError {
    case access(OSStatus), invalidKey, environmentReadOnly
    var errorDescription: String? {
        switch self {
        case .access(let status): return "Keychain access failed (\(status)). Allow Voxa access to its OpenAI key, then retry setup."
        case .invalidKey: return "Enter a non-empty API key without line breaks."
        case .environmentReadOnly: return "OPENAI_API_KEY is configured through the environment and cannot be edited here."
        }
    }
}

/// Security can wait for user authorization. All calls run on this serial worker, never the UI.
final class Keychain: @unchecked Sendable {
    static let service = "com.voxa"
    static let account = "OPENAI_API_KEY"
    private let worker = DispatchQueue(label: "com.voxa.keychain", qos: .userInitiated)
    private let read: () throws -> String?
    private let write: (String) throws -> Void
    private let environment: () -> String?

    init(service: String = Keychain.service, account: String = Keychain.account,
         read: (() throws -> String?)? = nil, write: ((String) throws -> Void)? = nil,
         environment: @escaping () -> String? = { ProcessInfo.processInfo.environment["OPENAI_API_KEY"] }) {
        self.read = read ?? { try Keychain.readNative(service: service, account: account) }
        self.write = write ?? { try Keychain.writeNative($0, service: service, account: account) }
        self.environment = environment
    }

    func value(source: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result {
                    if source == "env" { return Self.nonempty(self.environment()) }
                    return try Self.nonempty(self.read()) ?? Self.nonempty(self.environment())
                })
            }
        }
    }

    func save(_ key: String, source: String) async throws {
        guard source != "env" else { throw KeychainError.environmentReadOnly }
        guard let key = Self.nonempty(key), !key.utf8.contains(13), !key.utf8.contains(10) else {
            throw KeychainError.invalidKey
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async { continuation.resume(with: Result { try self.write(key) }) }
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func readNative(service: String, account: String) throws -> String? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.access(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidKey
        }
        return key
    }

    private static func writeNative(_ key: String, service: String, account: String) throws {
        let request = query(service: service, account: account)
        var lookup = request
        lookup[kSecReturnPersistentRef as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var reference: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &reference)
        let data = Data(key.utf8)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        } else if status == errSecSuccess, let reference {
            // Update the one item lookup selected, preserving its access control and avoiding
            // changes to any duplicate entries in other keychains in the user's search list.
            status = SecItemUpdate([kSecValuePersistentRef as String: reference] as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.access(status) }
    }
}
