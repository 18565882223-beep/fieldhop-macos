import Foundation
import Security

final class PhoneNumberStore {
    private let service = "local.sms-code-menubar"
    private let account = "default-phone-number"

    func load() -> String? {
        load(account: account)
    }

    func load(accountID: UUID) -> String? {
        load(account: keychainAccount(for: accountID))
    }

    private func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func save(_ phoneNumber: String) throws {
        try save(phoneNumber, account: account)
    }

    func save(_ phoneNumber: String, accountID: UUID) throws {
        try save(phoneNumber, account: keychainAccount(for: accountID))
    }

    private func save(_ phoneNumber: String, account: String) throws {
        let normalized = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try delete(account: account)
            return
        }

        let data = Data(normalized.utf8)
        var query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw RuntimeError("保存默认手机号失败：\(addStatus)")
            }
            return
        }

        guard status == errSecSuccess else {
            throw RuntimeError("保存默认手机号失败：\(status)")
        }
    }

    func delete() throws {
        try delete(account: account)
    }

    func delete(accountID: UUID) throws {
        try delete(account: keychainAccount(for: accountID))
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RuntimeError("删除默认手机号失败：\(status)")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func keychainAccount(for accountID: UUID) -> String {
        "phone-account-\(accountID.uuidString)"
    }
}
