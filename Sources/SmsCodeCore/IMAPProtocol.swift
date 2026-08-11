import Foundation

public struct IMAPMailboxState: Equatable {
    public let uidValidity: UInt64
    public let maximumUID: UInt64

    public init(uidValidity: UInt64, maximumUID: UInt64) {
        self.uidValidity = uidValidity
        self.maximumUID = maximumUID
    }
}

public protocol IMAPMailboxClient: AnyObject {
    func connect(username: String, password: String, requiresClientID: Bool) async throws
    func mailboxState() async throws -> IMAPMailboxState
    func fetchMessages(afterUID: UInt64) async throws -> EmailMessageFetchBatch
    func disconnect() async
    func cancel()
}

public enum IMAPAuthenticationMethod: String, Equatable {
    case login = "LOGIN"
    case plain = "AUTHENTICATE PLAIN"
}

public enum IMAPUsernameMode: String, Equatable {
    case fullAddress = "完整邮箱地址"
    case localPart = "本地部分用户名"
}

public enum IMAPCapabilitySupport: String, Equatable {
    case unavailable = "未获取到能力"
    case undeclared = "未声明"
    case unsupported = "明确不支持"
    case supported = "支持"
}

public struct IMAPCapabilitySummary: Equatable {
    public let wasRetrieved: Bool
    public let tokens: [String]

    public init(wasRetrieved: Bool, tokens: [String]) {
        self.wasRetrieved = wasRetrieved
        self.tokens = Array(
            Set(
                tokens.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }.filter { !$0.isEmpty }
            )
        ).sorted()
    }

    public static var unavailable: IMAPCapabilitySummary {
        IMAPCapabilitySummary(wasRetrieved: false, tokens: [])
    }

    public var supportsPlain: Bool {
        tokens.contains("AUTH=PLAIN")
    }

    public var supportsLogin: Bool {
        tokens.contains("AUTH=LOGIN")
    }

    public var loginDisabled: Bool {
        tokens.contains("LOGINDISABLED")
    }

    public var plainSupport: IMAPCapabilitySupport {
        guard wasRetrieved else { return .unavailable }
        return supportsPlain ? .supported : .undeclared
    }

    public var authLoginSupport: IMAPCapabilitySupport {
        guard wasRetrieved else { return .unavailable }
        return supportsLogin ? .supported : .undeclared
    }

    public var loginCommandSupport: IMAPCapabilitySupport {
        guard wasRetrieved else { return .unavailable }
        return loginDisabled ? .unsupported : .undeclared
    }

    public var authenticationRelatedTokens: [String] {
        tokens.filter {
            $0.hasPrefix("AUTH=")
                || ["ID", "LOGINDISABLED", "SASL-IR", "STARTTLS"].contains($0)
        }
    }

    public var displayText: String {
        guard wasRetrieved else {
            return "获取状态：\(IMAPCapabilitySupport.unavailable.rawValue)"
        }
        let related = authenticationRelatedTokens.isEmpty
            ? "无认证相关声明"
            : authenticationRelatedTokens.joined(separator: " ")
        return [
            "获取状态：已获取",
            "认证相关声明：\(related)",
            "AUTH=PLAIN：\(plainSupport.rawValue)",
            "AUTH=LOGIN：\(authLoginSupport.rawValue)",
            "LOGIN 命令：\(loginCommandSupport.rawValue)"
        ].joined(separator: "\n")
    }
}

public struct IMAPAuthenticationAttempt: Equatable {
    public let usernameMode: IMAPUsernameMode
    public let method: IMAPAuthenticationMethod
    public let completion: IMAPCompletionStatus
    public let sanitizedResponse: String

    public init(
        usernameMode: IMAPUsernameMode,
        method: IMAPAuthenticationMethod,
        completion: IMAPCompletionStatus,
        sanitizedResponse: String = ""
    ) {
        self.usernameMode = usernameMode
        self.method = method
        self.completion = completion
        self.sanitizedResponse = String(sanitizedResponse.prefix(160))
    }

    public var displayText: String {
        let response = sanitizedResponse.isEmpty
            ? IMAPResponseParser.defaultSanitizedAuthenticationResponse(for: completion)
            : sanitizedResponse
        return "用户名=\(usernameMode.rawValue)；认证方式=\(method.rawValue)；响应类别=\(completion.rawValue)；脱敏响应=\(response)"
    }
}

public struct IMAPConnectionEndpointDiagnostic: Equatable {
    public let host: String
    public let port: Int
    public let usesTLS: Bool

    public init(host: String, port: Int, usesTLS: Bool) {
        self.host = host.lowercased()
        self.port = port
        self.usesTLS = usesTLS
    }

    public var displayText: String {
        "\(usesTLS ? "隐式 TLS" : "未启用 TLS") · \(host):\(port)"
    }
}

public enum IMAPAuthenticationConclusion: String, Equatable {
    case connected = "认证成功，已建立只读 IMAP 连接"
    case authenticationRejected = "认证方式被服务器识别，但账号或专用密码未通过"
    case authenticationUnsupported = "服务器明确禁用 LOGIN，且未声明可用的 AUTHENTICATE PLAIN"
    case capabilityUnavailable = "未能取得服务器能力，无法安全决定认证方式"
    case protocolFailure = "IMAP 响应不符合预期，无法继续认证"
    case transportFailure = "TLS 或网络连接未建立，尚未进入认证"
}

public struct IMAPAuthenticationDiagnostic: Equatable {
    public let endpoint: IMAPConnectionEndpointDiagnostic
    public let capabilities: IMAPCapabilitySummary
    public let attempts: [IMAPAuthenticationAttempt]
    public let conclusion: IMAPAuthenticationConclusion

    public init(
        endpoint: IMAPConnectionEndpointDiagnostic,
        capabilities: IMAPCapabilitySummary,
        attempts: [IMAPAuthenticationAttempt],
        conclusion: IMAPAuthenticationConclusion
    ) {
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.attempts = Array(attempts.prefix(2))
        self.conclusion = conclusion
    }

    public var displayText: String {
        let attempted: String
        if attempts.isEmpty {
            attempted = "未发送认证尝试"
        } else {
            attempted = attempts.enumerated().map { index, attempt in
                "\(index + 1). \(attempt.displayText)"
            }.joined(separator: "\n")
        }
        return [
            "连接：\(endpoint.displayText)",
            "CAPABILITY：\n\(capabilities.displayText)",
            "认证尝试：\n\(attempted)",
            "最终结论：\(conclusion.rawValue)"
        ].joined(separator: "\n")
    }
}

public struct IMAPAuthenticationFailure: Error, LocalizedError, Equatable {
    public let diagnostic: IMAPAuthenticationDiagnostic

    public init(diagnostic: IMAPAuthenticationDiagnostic) {
        self.diagnostic = diagnostic
    }

    public var errorDescription: String? {
        [
            "88 邮箱连接失败",
            diagnostic.displayText,
            "处理建议：请在 88 网页端“设置 → 客户端设置 → 配置帮助”核对实际服务器参数，并重新生成专用密码后再试。"
        ].joined(separator: "\n")
    }
}

public enum IMAPAuthenticationPlanner {
    public static func primaryAttempt(
        capabilities: IMAPCapabilitySummary
    ) -> (usernameMode: IMAPUsernameMode, method: IMAPAuthenticationMethod)? {
        if capabilities.loginDisabled || (!capabilities.supportsLogin && capabilities.supportsPlain) {
            guard capabilities.supportsPlain else { return nil }
            return (.fullAddress, .plain)
        }
        return (.fullAddress, .login)
    }

    public static func fallbackAttempt(
        after attempt: IMAPAuthenticationAttempt,
        usernameIsFullAddress: Bool
    ) -> (usernameMode: IMAPUsernameMode, method: IMAPAuthenticationMethod)? {
        guard usernameIsFullAddress,
              attempt.usernameMode == .fullAddress,
              attempt.method == .login,
              attempt.completion == .no else {
            return nil
        }
        return (.localPart, .login)
    }
}

public enum IMAPCommandBuilder {
    public static func capability(tag: String) -> String {
        "\(tag) CAPABILITY\r\n"
    }

    public static func login(tag: String, username: String, password: String) -> String {
        "\(tag) LOGIN \(quoted(username)) \(quoted(password))\r\n"
    }

    public static func authenticatePlainStart(tag: String) -> String {
        "\(tag) AUTHENTICATE PLAIN\r\n"
    }

    public static func authenticatePlainResponse(username: String, password: String) -> String {
        let payload = "\u{0}\(username)\u{0}\(password)"
        return "\(Data(payload.utf8).base64EncodedString())\r\n"
    }

    public static func clientID(tag: String) -> String {
        "\(tag) ID (\"name\" \"SmsCodeMenuBar\" \"version\" \"1.0\" \"vendor\" \"local\")\r\n"
    }

    public static func examineInbox(tag: String) -> String {
        "\(tag) EXAMINE INBOX\r\n"
    }

    public static func searchAll(tag: String) -> String {
        "\(tag) UID SEARCH ALL\r\n"
    }

    public static func search(afterUID: UInt64, tag: String) -> String {
        let firstUID = afterUID == UInt64.max ? UInt64.max : afterUID + 1
        return "\(tag) UID SEARCH UID \(firstUID):*\r\n"
    }

    public static func fetch(uid: UInt64, tag: String) -> String {
        "\(tag) UID FETCH \(uid) (UID INTERNALDATE BODY.PEEK[])\r\n"
    }

    public static func logout(tag: String) -> String {
        "\(tag) LOGOUT\r\n"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return "\"\(escaped)\""
    }
}

public enum IMAPCompletionStatus: String, Equatable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
}

public enum IMAPProtocolError: Error, Equatable {
    case malformedResponse
    case missingUIDValidity
    case missingLiteral
    case commandFailed(String)
    case responseTooLarge
}

public enum IMAPResponseParser {
    public static func capabilitySummary(in data: Data) -> IMAPCapabilitySummary {
        let capabilities = latin1String(data)
            .split(whereSeparator: \.isNewline)
            .filter { $0.uppercased().hasPrefix("* CAPABILITY ") }
            .flatMap { $0.split(whereSeparator: \.isWhitespace).dropFirst(2) }
            .map { $0.uppercased() }
        return IMAPCapabilitySummary(wasRetrieved: !capabilities.isEmpty, tokens: capabilities)
    }

    public static func completionStatus(tag: String, in data: Data) -> IMAPCompletionStatus? {
        let text = latin1String(data)
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(
            pattern: "(?:^|\\r?\\n)\(escaped)\\s+(OK|NO|BAD)(?:\\s|$)",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        return IMAPCompletionStatus(rawValue: nsText.substring(with: match.range(at: 1)).uppercased())
    }

    public static func requireOK(tag: String, in data: Data) throws {
        guard let status = completionStatus(tag: tag, in: data) else {
            throw IMAPProtocolError.malformedResponse
        }
        guard status == .ok else {
            throw IMAPProtocolError.commandFailed(status.rawValue)
        }
    }

    public static func sanitizedAuthenticationResponse(tag: String, in data: Data) -> String {
        guard let status = completionStatus(tag: tag, in: data) else {
            return "未取得有效的认证完成响应"
        }
        let text = latin1String(data).lowercased()
        if text.contains("password")
            || text.contains("credential")
            || text.contains("login error")
            || text.contains("authentication failed")
            || text.contains("authenticate failed") {
            return "登录信息或专用密码被服务端拒绝"
        }
        if text.contains("too many")
            || text.contains("rate limit")
            || text.contains("temporarily blocked")
            || text.contains("try again later") {
            return "认证尝试受限，请稍后重试"
        }
        if text.contains("imap") && (text.contains("disabled") || text.contains("not enabled")) {
            return "IMAP 服务未开启或被服务端禁用"
        }
        if text.contains("not supported") || text.contains("unsupported") {
            return "当前认证方式不受服务端支持"
        }
        if text.contains("risk") || text.contains("security") || text.contains("policy") {
            return "账号安全策略拒绝了本次认证"
        }
        return defaultSanitizedAuthenticationResponse(for: status)
    }

    public static func defaultSanitizedAuthenticationResponse(
        for status: IMAPCompletionStatus
    ) -> String {
        switch status {
        case .ok:
            return "服务端确认认证成功"
        case .no:
            return "服务端拒绝认证，未提供可安全显示的详细原因"
        case .bad:
            return "服务端拒绝认证命令或协议格式"
        }
    }

    public static func uidValidity(in data: Data) throws -> UInt64 {
        let text = latin1String(data)
        guard let value = firstCapture(#"UIDVALIDITY\s+(\d+)"#, in: text).flatMap(UInt64.init) else {
            throw IMAPProtocolError.missingUIDValidity
        }
        return value
    }

    public static func searchUIDs(in data: Data) -> [UInt64] {
        let text = latin1String(data)
        guard let line = firstCapture(#"(?:^|\r?\n)\*\s+SEARCH(?:\s+([^\r\n]*))?"#, in: text) else {
            return []
        }
        return line.split(whereSeparator: \.isWhitespace).compactMap { UInt64($0) }
    }

    public static func literal(in data: Data) throws -> Data {
        let text = latin1String(data)
        guard let regex = try? NSRegularExpression(pattern: #"\{(\d+)\}\r?\n"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let count = UInt64((text as NSString).substring(with: match.range(at: 1))) else {
            throw IMAPProtocolError.missingLiteral
        }
        let start = match.range.location + match.range.length
        guard count <= UInt64(Int.max) else { throw IMAPProtocolError.responseTooLarge }
        let end = start + Int(count)
        guard start >= 0, end <= data.count else { throw IMAPProtocolError.missingLiteral }
        return data.subdata(in: start..<end)
    }

    public static func internalDate(in data: Data) -> Date? {
        let text = latin1String(data)
        guard let raw = firstCapture(#"INTERNALDATE\s+\"([^\"]+)\""#, in: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: raw)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func latin1String(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}
