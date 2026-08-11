import Foundation

public enum EmailProviderPreset: String, CaseIterable, Codable, Equatable {
    case gmail
    case outlook
    case qq
    case perfect88
    case netease163
    case netease126
    case custom

    public var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook / Hotmail（首版可能不可用）"
        case .qq: return "QQ 邮箱"
        case .perfect88: return "网易 88 邮箱 / 88 邮箱"
        case .netease163: return "163 邮箱"
        case .netease126: return "126 邮箱"
        case .custom: return "自定义"
        }
    }

    public var host: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .outlook: return "outlook.office365.com"
        case .qq: return "imap.qq.com"
        case .perfect88: return "imap.88.com"
        case .netease163: return "imap.163.com"
        case .netease126: return "imap.126.com"
        case .custom: return ""
        }
    }

    public var port: Int { 993 }
    public var useTLS: Bool { true }

    public var domainSuffixes: [String] {
        switch self {
        case .gmail: return ["gmail.com"]
        case .outlook: return ["outlook.com", "hotmail.com", "live.com"]
        case .qq: return ["qq.com"]
        case .perfect88: return ["88.com"]
        case .netease163: return ["163.com"]
        case .netease126: return ["126.com"]
        case .custom: return []
        }
    }

    public func matches(emailAddress: String) -> Bool {
        guard let domain = emailAddress.split(separator: "@", maxSplits: 1).last else { return false }
        let normalized = domain.lowercased()
        return domainSuffixes.contains(normalized)
    }
}

public struct EmailAccount: Codable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var emailAddress: String
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var username: String
    public var isEnabled: Bool
    public var uidValidity: UInt64?
    public var lastSeenUID: UInt64?
    public var shortcut: KeyboardShortcutDescriptor
    public var waitDurationMinutes: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        emailAddress: String,
        host: String,
        port: Int = 993,
        useTLS: Bool = true,
        username: String? = nil,
        isEnabled: Bool = true,
        uidValidity: UInt64? = nil,
        lastSeenUID: UInt64? = nil,
        shortcut: KeyboardShortcutDescriptor = KeyboardShortcutDescriptor(
            keyCode: 21,
            modifierFlags: 2560,
            displayName: "⌥⌘4"
        ),
        waitDurationMinutes: Int = 10
    ) {
        self.id = id
        self.displayName = displayName
        self.emailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
        self.useTLS = useTLS
        self.username = (username ?? emailAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.uidValidity = uidValidity
        self.lastSeenUID = lastSeenUID
        self.shortcut = shortcut
        self.waitDurationMinutes = min(max(waitDurationMinutes, 5), 15)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, emailAddress, host, port, useTLS, username, isEnabled, uidValidity, lastSeenUID
        case shortcut, waitDurationMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        useTLS = try container.decode(Bool.self, forKey: .useTLS)
        username = try container.decode(String.self, forKey: .username)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        uidValidity = try container.decodeIfPresent(UInt64.self, forKey: .uidValidity)
        lastSeenUID = try container.decodeIfPresent(UInt64.self, forKey: .lastSeenUID)
        shortcut = try container.decodeIfPresent(KeyboardShortcutDescriptor.self, forKey: .shortcut)
            ?? KeyboardShortcutDescriptor(keyCode: 21, modifierFlags: 2560, displayName: "⌥⌘4")
        waitDurationMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .waitDurationMinutes) ?? 10, 5), 15)
    }

    public var maskedEmail: String {
        EmailLogSanitizer.maskEmail(emailAddress)
    }

    public var requiresIMAPID: Bool {
        let normalized = host.lowercased()
        return normalized == "imap.163.com" || normalized == "imap.126.com"
    }

    public var isPerfect88IMAP: Bool {
        host.lowercased() == "imap.88.com"
    }
}

public struct EmailAccountList: Codable, Equatable {
    public private(set) var accounts: [EmailAccount]

    public init(accounts: [EmailAccount] = []) {
        self.accounts = accounts
    }

    public var enabledAccounts: [EmailAccount] {
        accounts.filter(\.isEnabled)
    }

    public func account(id: UUID) -> EmailAccount? {
        accounts.first { $0.id == id }
    }

    public mutating func upsert(_ account: EmailAccount) {
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

public final class EmailAccountStore {
    private let defaults: UserDefaults
    private let accountsKey: String
    private let enabledKey: String

    public init(
        defaults: UserDefaults = .standard,
        accountsKey: String = "emailAccounts.v1",
        enabledKey: String = "emailMonitoringEnabled.v1"
    ) {
        self.defaults = defaults
        self.accountsKey = accountsKey
        self.enabledKey = enabledKey
    }

    public func load() -> EmailAccountList {
        guard let data = defaults.data(forKey: accountsKey),
              let accounts = try? JSONDecoder().decode(EmailAccountList.self, from: data) else {
            return EmailAccountList()
        }
        return accounts
    }

    public func save(_ accounts: EmailAccountList) throws {
        let data = try JSONEncoder().encode(accounts)
        defaults.set(data, forKey: accountsKey)
    }

    public var isMonitoringEnabled: Bool {
        get {
            guard defaults.object(forKey: enabledKey) != nil else { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            defaults.set(newValue, forKey: enabledKey)
        }
    }
}

public enum EmailConnectionPhase: String, Equatable {
    case stopped
    case connecting
    case listening
    case retrying
    case failed

    public var title: String {
        switch self {
        case .stopped: return "已停用"
        case .connecting: return "连接中"
        case .listening: return "监听中"
        case .retrying: return "等待重连"
        case .failed: return "连接失败"
        }
    }
}

public struct EmailConnectionStatus: Equatable {
    public let phase: EmailConnectionPhase
    public let detail: String?
    public let diagnostic: EmailPollDiagnostic?

    public init(
        phase: EmailConnectionPhase,
        detail: String? = nil,
        diagnostic: EmailPollDiagnostic? = nil
    ) {
        self.phase = phase
        self.detail = detail
        self.diagnostic = diagnostic
    }

    public var displayText: String {
        guard let detail, !detail.isEmpty else { return phase.title }
        return "\(phase.title)：\(detail)"
    }

    public var diagnosticText: String {
        diagnostic?.summaryText ?? "尚无监听诊断"
    }
}

public enum EmailLogSanitizer {
    public static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "***" }
        let local = parts[0]
        let visible = local.prefix(1)
        return "\(visible)***@\(parts[1])"
    }

    public static func sanitizeError(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "***@***")
        }
        if let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9+/=_-]{12,}\b"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "***")
        }
        return String(result.prefix(160))
    }
}
