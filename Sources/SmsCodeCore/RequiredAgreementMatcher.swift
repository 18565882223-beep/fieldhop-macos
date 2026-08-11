import Foundation

public struct RequiredAgreementMatcher {
    public init() {}

    public func isAgreementCheckbox(
        role: String?,
        title: String?,
        description: String?,
        value: String?,
        context: String?
    ) -> Bool {
        guard role == "AXCheckBox" else { return false }

        let directText = normalizedText(title: title, description: description, value: value, context: nil)
        let fullText = normalizedText(title: title, description: description, value: value, context: context)
        guard !fullText.isEmpty else { return false }
        guard hasAgreementSignal(fullText) else { return false }
        guard !hasBlockedSignal(directText: directText, fullText: fullText) else { return false }

        return true
    }

    public func describeCandidate(
        role: String?,
        title: String?,
        description: String?,
        value: String?,
        context: String?
    ) -> String {
        [
            "role=\(role ?? "nil")",
            "title=\(title ?? "nil")",
            "description=\(description ?? "nil")",
            "value=\(value ?? "nil")",
            "context=\((context ?? "nil").prefix(80))"
        ].joined(separator: " ")
    }

    private func normalizedText(title: String?, description: String?, value: String?, context: String?) -> String {
        [title, description, value, context]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func hasAgreementSignal(_ text: String) -> Bool {
        let signals = [
            "协议",
            "隐私",
            "条款",
            "同意",
            "agree",
            "terms",
            "privacy"
        ]
        return signals.contains { text.contains($0) }
    }

    private func hasBlockedSignal(directText: String, fullText: String) -> Bool {
        let blockedEverywhere = [
            "营销",
            "推广",
            "促销",
            "接收短信",
            "接收 短信",
            "订阅",
            "自动登录",
            "记住我",
            "remember me",
            "auto login",
            "marketing",
            "promotion",
            "subscribe",
            "subscription",
            "newsletter"
        ]
        if blockedEverywhere.contains(where: { fullText.contains($0) }) {
            return true
        }

        let directOnlyBlocked = [
            "第三方",
            "授权",
            "authorize"
        ]
        return directOnlyBlocked.contains { directText.contains($0) }
    }
}
