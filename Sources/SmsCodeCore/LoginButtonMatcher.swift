import Foundation

public struct LoginButtonMatcher {
    public static let directLoginKeywords: [String] = [
        "登录",
        "登 录",
        "登錄",
        "立即登录",
        "马上登录",
        "现在登录",
        "同意并登录",
        "确认登录",
        "进入",
        "完成",
        "登录/注册",
        "登录或注册",
        "登录 · 注册",
        "login",
        "log in",
        "sign in",
        "login / register",
        "login or register"
    ]

    public static let generalSubmitKeywords: [String] = [
        "确定",
        "确认",
        "下一步",
        "验证",
        "提交",
        "submit",
        "continue",
        "next",
        "verify",
        "confirm",
        "ok",
        "done",
        "go",
        "start",
        "get started",
        "获取",
        "发送",
        "send"
    ]

    public static let defaultKeywords: [String] = directLoginKeywords + generalSubmitKeywords

    public static let actionableRoles: Set<String> = [
        "AXButton",
        "AXMenuButton",
        "AXLink",
        "AXMenuItem",
        "AXPopUpButton",
        "AXCheckBox",
        "AXRadioButton"
    ]

    private let keywords: [String]
    private let directLoginIndicators: [String]
    private let actionableRoles: Set<String>

    public init(keywords: [String] = defaultKeywords) {
        self.keywords = keywords.map { $0.lowercased() }
        self.directLoginIndicators = LoginButtonMatcher.directLoginKeywords.map { $0.lowercased() }
        self.actionableRoles = LoginButtonMatcher.actionableRoles
    }

    public func isActionableRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return actionableRoles.contains(role)
    }

    public func isLoginButton(role: String?, title: String?, description: String?, value: String?) -> Bool {
        guard isActionableRole(role) else { return false }
        guard !isBlacklisted(title: title, description: description, value: value) else { return false }

        let candidates = collectCandidates(title: title, description: description, value: value)
        guard !candidates.isEmpty else { return false }

        for candidate in candidates {
            if isLoginDominant(candidate) {
                return true
            }

            for keyword in keywords {
                if candidate.contains(keyword) {
                    return true
                }
            }
        }

        return false
    }

    public func isClickableLoginText(title: String?, description: String?, value: String?) -> Bool {
        guard !isBlacklisted(title: title, description: description, value: value) else { return false }

        let candidates = collectCandidates(title: title, description: description, value: value)
        guard !candidates.isEmpty else { return false }

        let textButtonKeywords = directLoginIndicators + [
            "确定",
            "确认",
            "下一步",
            "提交",
            "submit",
            "continue",
            "next",
            "confirm",
            "ok",
            "done",
            "go"
        ].map { $0.lowercased() }

        for candidate in candidates {
            if isLoginDominant(candidate) {
                return true
            }

            if textButtonKeywords.contains(where: { candidate == $0 || candidate.contains($0) }) {
                return true
            }
        }

        return false
    }

    public func isBlacklisted(title: String?, description: String?, value: String?) -> Bool {
        let candidates = collectCandidates(title: title, description: description, value: value)
        guard !candidates.isEmpty else { return false }

        for candidate in candidates {
            let hardBlacklist = [
                "微信登录",
                "微博登录",
                "qq登录",
                "抖音登录",
                "飞书登录",
                "火山登录",
                "员工登录",
                "其他方式登录",
                "其它登录方式",
                "other login",
                "扫描二维码登录",
                "扫码登录",
                "密码登录",
                "短信登录",
                "登录或完成注册",
                "代表你同意",
                "用户协议",
                "隐私政策",
                "重新发送",
                "重发",
                "resend",
                "发送验证码",
                "获取验证码",
                "get code",
                "send code"
            ]

            if hardBlacklist.contains(where: { candidate.contains($0) }) {
                return true
            }

            if isLoginDominant(candidate) {
                return false
            }

            if candidate.contains("登录") || candidate.contains("login") || candidate.contains("sign in") || candidate.contains("登錄") {
                return false
            }

            let pureBlacklist = [
                "注册",
                "register",
                "sign up",
                "免费注册",
                "立即注册",
                "微信登录",
                "微博登录",
                "qq登录",
                "抖音登录",
                "飞书登录",
                "火山登录",
                "员工登录",
                "其他方式登录",
                "其它登录方式",
                "other login",
                "取消",
                "返回",
                "关闭",
                "cancel",
                "back",
                "close",
                "reset",
                "重置",
                "重新发送",
                "重发",
                "resend",
                "发送验证码",
                "获取验证码",
                "get code",
                "send code",
                "忘记密码",
                "forgot",
                "清空",
                "清除",
                "clear",
                "退出",
                "logout",
                "登出"
            ]

            for word in pureBlacklist {
                if candidate.contains(word) {
                    return true
                }
            }
        }

        return false
    }

    public func describeCandidate(role: String?, title: String?, description: String?, value: String?) -> String {
        let parts = [
            "role=\(role ?? "nil")",
            "title=\(title ?? "nil")",
            "desc=\(description ?? "nil")",
            "value=\(value ?? "nil")"
        ]
        return parts.joined(separator: " ")
    }

    private func collectCandidates(title: String?, description: String?, value: String?) -> [String] {
        return [title, description, value]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func isLoginDominant(_ text: String) -> Bool {
        if text.contains("登录") || text.contains("login") || text.contains("sign in") || text.contains("登錄") {
            return true
        }

        for indicator in directLoginIndicators {
            if text.contains(indicator) {
                return true
            }
        }

        return false
    }
}
