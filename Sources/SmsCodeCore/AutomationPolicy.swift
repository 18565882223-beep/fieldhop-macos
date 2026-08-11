import Foundation

public enum AutoClickMode: String, Codable, Equatable {
    case trustedOnly
    case aggressive
    case off
}

public struct AutomationSettings: Codable, Equatable {
    public var autoClickMode: AutoClickMode
    public var allowedBundleIdentifiers: Set<String>
    public var allowedHosts: Set<String>
    public var autoCheckRequiredAgreement: Bool

    public init(
        autoClickMode: AutoClickMode = .trustedOnly,
        allowedBundleIdentifiers: Set<String> = [],
        allowedHosts: Set<String> = Self.defaultAllowedHosts,
        autoCheckRequiredAgreement: Bool = true
    ) {
        self.autoClickMode = autoClickMode
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.allowedHosts = allowedHosts
        self.autoCheckRequiredAgreement = autoCheckRequiredAgreement
    }

    private enum CodingKeys: String, CodingKey {
        case autoClickMode
        case allowedBundleIdentifiers
        case allowedHosts
        case autoCheckRequiredAgreement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoClickMode = try container.decodeIfPresent(AutoClickMode.self, forKey: .autoClickMode) ?? .trustedOnly
        allowedBundleIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .allowedBundleIdentifiers) ?? []
        allowedHosts = try container.decodeIfPresent(Set<String>.self, forKey: .allowedHosts) ?? Self.defaultAllowedHosts
        autoCheckRequiredAgreement = try container.decodeIfPresent(Bool.self, forKey: .autoCheckRequiredAgreement) ?? true
    }

    public static let defaultAllowedHosts: Set<String> = [
        "bilibili.com",
        "doubao.com",
        "kimi.com",
        "moonshot.cn",
        "coze.cn",
        "coze.com"
    ]
}

public struct AutomationTargetContext: Equatable {
    public let bundleIdentifier: String?
    public let applicationName: String?
    public let urlString: String?
    public let title: String?
    public let pageText: String?

    public init(
        bundleIdentifier: String? = nil,
        applicationName: String? = nil,
        urlString: String? = nil,
        title: String? = nil,
        pageText: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.urlString = urlString
        self.title = title
        self.pageText = pageText
    }
}

public struct AutoClickDecision: Equatable {
    public let isAllowed: Bool
    public let reason: String

    public init(isAllowed: Bool, reason: String) {
        self.isAllowed = isAllowed
        self.reason = reason
    }
}

public enum AutomationPermission: Equatable {
    case fillPhone
    case requestVerificationCode
    case clickLogin
}

public struct AutomationSafetyPolicy {
    public static let defaultRiskKeywords: [String] = [
        "支付",
        "付款",
        "提现",
        "转账",
        "收款",
        "修改密码",
        "重置密码",
        "找回密码",
        "绑定",
        "解绑",
        "删除",
        "注销",
        "身份验证",
        "实名认证",
        "银行卡",
        "余额",
        "purchase",
        "payment",
        "withdraw",
        "transfer",
        "delete account",
        "reset password"
    ]

    private let riskKeywords: [String]

    public init(riskKeywords: [String] = Self.defaultRiskKeywords) {
        self.riskKeywords = riskKeywords.map { $0.lowercased() }
    }

    public func decision(settings: AutomationSettings, context: AutomationTargetContext) -> AutoClickDecision {
        decision(settings: settings, context: context, permission: .clickLogin)
    }

    public func decision(
        settings: AutomationSettings,
        context: AutomationTargetContext,
        permission: AutomationPermission
    ) -> AutoClickDecision {
        if containsRiskKeyword(context) {
            return AutoClickDecision(isAllowed: false, reason: "页面含高风险词，禁止自动操作")
        }

        switch settings.autoClickMode {
        case .off:
            return AutoClickDecision(isAllowed: false, reason: "自动操作已关闭")
        case .aggressive:
            return AutoClickDecision(isAllowed: true, reason: "激进模式允许自动操作")
        case .trustedOnly:
            if isTrusted(context: context, settings: settings) {
                return AutoClickDecision(isAllowed: true, reason: "\(permission.reasonPrefix)白名单允许")
            }
            return AutoClickDecision(isAllowed: false, reason: "\(permission.reasonPrefix)名单外禁止")
        }
    }

    public func containsRiskKeyword(_ context: AutomationTargetContext) -> Bool {
        let searchable = [
            context.applicationName,
            context.bundleIdentifier,
            context.urlString,
            context.title,
            context.pageText
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        return riskKeywords.contains { searchable.contains($0) }
    }

    public func isTrusted(context: AutomationTargetContext, settings: AutomationSettings) -> Bool {
        if let bundleIdentifier = context.bundleIdentifier,
           settings.allowedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        guard let host = normalizedHost(from: context.urlString) else {
            return false
        }

        return settings.allowedHosts.contains { allowed in
            host == allowed || host.hasSuffix(".\(allowed)")
        }
    }

    public func normalizedHost(from urlString: String?) -> String? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URL(string: candidate)?.host?.lowercased() else {
            return nil
        }

        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private extension AutomationPermission {
    var reasonPrefix: String {
        switch self {
        case .fillPhone:
            return "填手机号："
        case .requestVerificationCode:
            return "获取验证码："
        case .clickLogin:
            return "点登录："
        }
    }
}
