import Foundation
import Security

public protocol DurableStoreAnchor: Sendable {
    func load(identifier: String) throws -> Data?
    func compareAndSwap(identifier: String, expected: Data?, replacement: Data) throws
}

public final class KeychainStoreAnchor: DurableStoreAnchor, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.worksbien.bank-reconciliation.engine-anchor") {
        self.service = service
    }

    public func load(identifier: String) throws -> Data? {
        var query = baseQuery(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw EngineError.integrityFailure("keychain anchor read failed: \(status)")
        }
        return data
    }

    public func compareAndSwap(identifier: String, expected: Data?, replacement: Data) throws {
        let current = try load(identifier: identifier)
        guard current == expected else { throw EngineError.integrityFailure("durable store anchor changed concurrently") }
        let query = baseQuery(identifier: identifier)
        let status: OSStatus
        if current == nil {
            var attributes = query
            attributes[kSecValueData as String] = replacement
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        } else {
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: replacement] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw EngineError.integrityFailure("keychain anchor write failed: \(status)")
        }
    }

    private func baseQuery(identifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier
        ]
    }
}
