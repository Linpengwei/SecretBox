import Foundation
import Security

/// Persistence boundary for the encoded local vault blob.
protocol RecordStoring {
    func loadData() -> Data?
    func save(_ data: Data)
    func clear()
}

/// Stores the vault in the login Keychain so records are not readable
/// from a plaintext plist on disk.
struct KeychainRecordStore: RecordStoring {
    let service: String
    let account: String

    init(service: String = "Hendrix.SecretBox", account: String = "localVault") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadData() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data) {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Non-persisting store for unit tests.
/// `nonisolated` keeps the compiler from inferring MainActor isolation from the
/// module default; an isolated deinit would hop executors on release and trip a
/// malloc abort in the Swift 6.2 concurrency runtime.
nonisolated final class InMemoryRecordStore: RecordStoring {
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    nonisolated deinit {}

    func loadData() -> Data? {
        data
    }

    func save(_ data: Data) {
        self.data = data
    }

    func clear() {
        data = nil
    }
}
