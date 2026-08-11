import Foundation
import Security

public protocol EmailCredentialBackend {
    func load(service: String, account: String) -> Data?
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct SecurityEmailCredentialBackend: EmailCredentialBackend {
    public init() {}

    public func load(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    public func save(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw EmailCredentialError.keychain(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw EmailCredentialError.keychain(status)
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EmailCredentialError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum EmailCredentialError: Error, Equatable {
    case emptyPassword
    case invalidEncoding
    case keychain(OSStatus)
}

public final class EmailCredentialStore {
    public static let service = "local.sms-code-menubar.email-otp"
    private let backend: EmailCredentialBackend

    public init(backend: EmailCredentialBackend = SecurityEmailCredentialBackend()) {
        self.backend = backend
    }

    public func load(accountID: UUID) -> String? {
        guard let data = backend.load(service: Self.service, account: accountID.uuidString),
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }
        return password
    }

    public func save(_ password: String, accountID: UUID) throws {
        guard !password.isEmpty else { throw EmailCredentialError.emptyPassword }
        guard let data = password.data(using: .utf8) else {
            throw EmailCredentialError.invalidEncoding
        }
        try backend.save(data, service: Self.service, account: accountID.uuidString)
    }

    public func delete(accountID: UUID) throws {
        try backend.delete(service: Self.service, account: accountID.uuidString)
    }
}
