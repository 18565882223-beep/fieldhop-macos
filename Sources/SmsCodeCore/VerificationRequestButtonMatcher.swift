import Foundation

public struct VerificationRequestButtonMatcher {
    public init() {}

    public func isActionableRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXButton"
            || role == "AXLink"
            || role == "AXMenuItem"
            || role == "AXStaticText"
            || role == "AXText"
    }

    public func isRequestCodeButton(
        role: String?,
        title: String?,
        description: String?,
        value: String?
    ) -> Bool {
        guard isActionableRole(role) else { return false }
        let text = normalizedText(title: title, description: description, value: value)
        guard !text.isEmpty else { return false }
        guard !isBlacklisted(text) else { return false }
        guard !isCountdownOrSentState(text) else { return false }
        guard hasStrongRequestCodeSignal(text) else { return false }

        let exactMatches = [
            "获取验证码",
            "发送验证码",
            "获取短信验证码",
            "发送短信验证码",
            "获取校验码",
            "发送校验码",
            "获取动态码",
            "发送动态码",
            "获取短信",
            "重新获取验证码",
            "重新获取校验码",
            "重新获取动态码",
            "免费获取验证码",
            "send code",
            "get code",
            "send sms",
            "get sms",
            "get sms code",
            "send verification code",
            "get verification code"
        ]
        if exactMatches.contains(text) {
            return true
        }

        let containsMatches = [
            "获取验证码",
            "发送验证码",
            "短信验证码",
            "获取动态码",
            "发送动态码",
            "获取校验码",
            "发送校验码",
            "获取短信",
            "重新获取验证码",
            "重新获取校验码",
            "重新获取动态码",
            "免费获取验证码",
            "send code",
            "get code",
            "send sms",
            "get sms",
            "sms code",
            "verification code"
        ]
        return containsMatches.contains { text.contains($0) }
    }

    public func describeCandidate(role: String?, title: String?, description: String?, value: String?) -> String {
        [
            "role=\(role ?? "nil")",
            "title=\(title ?? "nil")",
            "description=\(description ?? "nil")",
            "value=\(value ?? "nil")"
        ].joined(separator: " ")
    }

    private func normalizedText(title: String?, description: String?, value: String?) -> String {
        [title, description, value]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty } ?? ""
    }

    private func isBlacklisted(_ text: String) -> Bool {
        let blocked = [
            "登录",
            "注册",
            "下一步",
            "确认",
            "提交",
            "继续",
            "下一步",
            "next",
            "continue",
            "密码登录",
            "扫码",
            "微信",
            "支付宝",
            "qq",
            "apple"
        ]
        return blocked.contains { text.contains($0) }
    }

    private func hasStrongRequestCodeSignal(_ text: String) -> Bool {
        let strongSignals = [
            "码",
            "验证",
            "sms",
            "code"
        ]
        return strongSignals.contains { text.contains($0) }
    }

    private func isCountdownOrSentState(_ text: String) -> Bool {
        let sentHints = [
            "已发送",
            "后重发",
            "重新发送",
            "重发",
            "resend",
            "sent"
        ]
        if sentHints.contains(where: { text.contains($0) }) {
            return true
        }

        let countdownPattern = #"\d+\s*(s|秒)"#
        return text.range(of: countdownPattern, options: .regularExpression) != nil
    }
}
