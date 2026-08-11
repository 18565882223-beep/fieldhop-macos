import Foundation

public struct EmailVerificationMessage: Equatable {
    public let accountID: UUID
    public let uid: UInt64
    public let date: Date
    public let subject: String
    public let body: String

    public init(accountID: UUID, uid: UInt64, date: Date, subject: String, body: String) {
        self.accountID = accountID
        self.uid = uid
        self.date = date
        self.subject = subject
        self.body = body
    }
}

public struct EmailMessageFetchDiagnostic: Equatable {
    public let uid: UInt64
    public let fetchSucceeded: Bool
    public let mimeSucceeded: Bool
    public let sanitizedError: String?

    public init(
        uid: UInt64,
        fetchSucceeded: Bool,
        mimeSucceeded: Bool,
        sanitizedError: String? = nil
    ) {
        self.uid = uid
        self.fetchSucceeded = fetchSucceeded
        self.mimeSucceeded = mimeSucceeded
        self.sanitizedError = sanitizedError
    }

    public var canAdvanceWatermark: Bool {
        fetchSucceeded && mimeSucceeded
    }
}

public struct EmailMessageFetchBatch: Equatable {
    public let discoveredUIDs: [UInt64]
    public let messages: [EmailVerificationMessage]
    public let diagnostics: [EmailMessageFetchDiagnostic]

    public init(
        discoveredUIDs: [UInt64],
        messages: [EmailVerificationMessage],
        diagnostics: [EmailMessageFetchDiagnostic]
    ) {
        self.discoveredUIDs = discoveredUIDs
        self.messages = messages
        self.diagnostics = diagnostics
    }
}

public struct EmailPollDiagnostic: Equatable {
    public var lastPollAt: Date?
    public var lastPollSucceeded: Bool?
    public var discoveredUIDCount: Int
    public var fetchSucceededCount: Int
    public var fetchFailedCount: Int
    public var mimeSucceededCount: Int
    public var mimeFailedCount: Int
    public var keywordMatchedCount: Int
    public var codeExtractedCount: Int
    public var highConfidenceCount: Int
    public var mediumConfidenceCount: Int
    public var lowConfidenceCount: Int
    public var lastExtractionSummary: String?
    public var lastSanitizedError: String?

    public init(
        lastPollAt: Date? = nil,
        lastPollSucceeded: Bool? = nil,
        discoveredUIDCount: Int = 0,
        fetchSucceededCount: Int = 0,
        fetchFailedCount: Int = 0,
        mimeSucceededCount: Int = 0,
        mimeFailedCount: Int = 0,
        keywordMatchedCount: Int = 0,
        codeExtractedCount: Int = 0,
        highConfidenceCount: Int = 0,
        mediumConfidenceCount: Int = 0,
        lowConfidenceCount: Int = 0,
        lastExtractionSummary: String? = nil,
        lastSanitizedError: String? = nil
    ) {
        self.lastPollAt = lastPollAt
        self.lastPollSucceeded = lastPollSucceeded
        self.discoveredUIDCount = discoveredUIDCount
        self.fetchSucceededCount = fetchSucceededCount
        self.fetchFailedCount = fetchFailedCount
        self.mimeSucceededCount = mimeSucceededCount
        self.mimeFailedCount = mimeFailedCount
        self.keywordMatchedCount = keywordMatchedCount
        self.codeExtractedCount = codeExtractedCount
        self.highConfidenceCount = highConfidenceCount
        self.mediumConfidenceCount = mediumConfidenceCount
        self.lowConfidenceCount = lowConfidenceCount
        self.lastExtractionSummary = lastExtractionSummary
        self.lastSanitizedError = lastSanitizedError
    }

    public var summaryText: String {
        let pollText: String
        switch lastPollSucceeded {
        case .some(true): pollText = "最近轮询成功"
        case .some(false): pollText = "最近轮询失败"
        case .none: pollText = "尚未轮询"
        }
        let errorText = lastSanitizedError.map { "，错误=\($0)" } ?? ""
        let extractionText = lastExtractionSummary.map { "，识别=\($0)" } ?? ""
        let manualText = mediumConfidenceCount > 0 ? "，发现疑似验证码，需手动确认" : ""
        return "\(pollText)，新UID=\(discoveredUIDCount)，FETCH \(fetchSucceededCount)/\(fetchFailedCount)，MIME \(mimeSucceededCount)/\(mimeFailedCount)，关键词=\(keywordMatchedCount)，抽码=\(codeExtractedCount)，置信度 高/中/低=\(highConfidenceCount)/\(mediumConfidenceCount)/\(lowConfidenceCount)\(manualText)\(extractionText)\(errorText)"
    }
}

public enum VerificationCodeSource: Equatable {
    case sms
    case email(accountID: UUID, uid: UInt64)
}

public struct VerificationCodeCandidate: Equatable {
    public let code: String
    public let date: Date
    public let source: VerificationCodeSource

    public init(code: String, date: Date, source: VerificationCodeSource) {
        self.code = code
        self.date = date
        self.source = source
    }
}

public struct EmailVerificationCodeSelector {
    public let extractor: VerificationCodeExtractor
    public let timeWindow: TimeInterval

    public init(
        extractor: VerificationCodeExtractor = VerificationCodeExtractor(),
        timeWindow: TimeInterval = 180
    ) {
        self.extractor = extractor
        self.timeWindow = timeWindow
    }

    public func candidate(
        from message: EmailVerificationMessage,
        now: Date = Date()
    ) -> VerificationCodeCandidate? {
        let assessment = assess(message: message)
        guard assessment.confidence == .high,
              let code = assessment.code else {
            return nil
        }
        let searchable = "\(message.subject)\n\(message.body)"
        guard extractor.containsKeyword(searchable) || !assessment.reasons.isEmpty else {
            return nil
        }
        return VerificationCodeCandidate(
            code: code,
            date: now,
            source: .email(accountID: message.accountID, uid: message.uid)
        )
    }

    public func assess(message: EmailVerificationMessage) -> VerificationCodeExtractionAssessment {
        extractor.assessEmail(subject: message.subject, body: message.body)
    }

    public func waitingResult(message: EmailVerificationMessage) -> EmailWaitExtractionResult {
        let assessment = assess(message: message)
        if assessment.candidateCount == 0 { return .none }
        if assessment.candidateCount == 1 {
            if let code = assessment.code { return .code(code) }
            let combined = "\(message.subject)\n\(message.body)"
            if let code = extractor.extract(from: combined), !containsSeparatedDigits(in: combined) {
                return .code(code)
            }
            return .none
        }
        if assessment.confidence == .high, let code = assessment.code {
            return .code(code)
        }
        return .ambiguous(assessment.sanitizedSummary)
    }

    private func containsSeparatedDigits(in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)\d{2,4}[ -]\d{2,4}(?!\d)"#) else {
            return true
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

public enum EmailWaitExtractionResult: Equatable {
    case code(String)
    case ambiguous(String)
    case none
}

public enum EmailFillGateDecision: Equatable {
    case fill(targetHost: String)
    case clipboardOnly(reason: String)
}

public struct EmailFillGate {
    public init() {}

    public func decide(
        isPaused: Bool,
        frontmostBundleIdentifier: String?,
        hasFocusedElement: Bool,
        isVerificationField: Bool,
        targetHost: String?
    ) -> EmailFillGateDecision {
        if isPaused {
            return .clipboardOnly(reason: "App 已暂停")
        }
        guard frontmostBundleIdentifier == "com.google.Chrome" else {
            return .clipboardOnly(reason: "当前前台不是 Chrome")
        }
        guard hasFocusedElement, isVerificationField else {
            return .clipboardOnly(reason: "当前焦点不是验证码框")
        }
        guard let targetHost, !targetHost.isEmpty else {
            return .clipboardOnly(reason: "无法确认当前网页 host")
        }
        return .fill(targetHost: targetHost)
    }
}
