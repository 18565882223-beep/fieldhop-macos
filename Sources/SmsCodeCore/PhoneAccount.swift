import Foundation

public struct KeyboardShortcutDescriptor: Codable, Equatable, Hashable {
    public let keyCode: UInt32
    public let modifierFlags: UInt32
    public let displayName: String

    public init(keyCode: UInt32, modifierFlags: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.displayName = displayName
    }
}

public struct PhoneAccount: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var shortcut: KeyboardShortcutDescriptor
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        shortcut: KeyboardShortcutDescriptor,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }
}

public struct PhoneAccountList: Codable, Equatable {
    public private(set) var accounts: [PhoneAccount]

    public init(accounts: [PhoneAccount] = []) {
        self.accounts = accounts
    }

    public var enabledAccounts: [PhoneAccount] {
        accounts.filter(\.isEnabled)
    }

    public func account(id: UUID) -> PhoneAccount? {
        accounts.first { $0.id == id }
    }

    public mutating func upsert(_ account: PhoneAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
    }
}
