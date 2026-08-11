import Foundation

public enum VerificationCodeConfidence: String, Equatable {
    case high = "高置信"
    case medium = "中置信"
    case low = "低置信"
}

public struct VerificationCodeExtractionAssessment: Equatable {
    public let code: String?
    public let confidence: VerificationCodeConfidence
    public let candidateCount: Int
    public let reasons: [String]
    public let downgradeReasons: [String]

    public init(
        code: String?,
        confidence: VerificationCodeConfidence,
        candidateCount: Int,
        reasons: [String],
        downgradeReasons: [String] = []
    ) {
        self.code = code
        self.confidence = confidence
        self.candidateCount = candidateCount
        self.reasons = reasons
        self.downgradeReasons = downgradeReasons
    }

    public var sanitizedSummary: String {
        let reasonText = reasons.prefix(3).joined(separator: "/")
        let downgradeText = downgradeReasons.isEmpty ? "" : "，降级=\(downgradeReasons.prefix(3).joined(separator: "/"))"
        return "\(confidence.rawValue)，候选=\(candidateCount)，理由=\(reasonText.isEmpty ? "无认证语义" : reasonText)\(downgradeText)"
    }
}

public struct VerificationCodeExtractor {
    public let keywords: [String]

    private static let maxEmailBodyCharacters = 24_000

    public init(keywords: [String] = VerificationCodeExtractor.defaultKeywords) {
        self.keywords = keywords
    }

    public static let defaultKeywords = [
        "验证码", "校验码", "动态码", "短信码", "确认码", "安全码",
        "verification", "verify", "code", "passcode", "otp", "one-time", "login code"
    ]

    private static let strongAuthTerms = [
        "验证码", "校验码", "动态码", "短信码", "确认码", "安全码", "登录码", "登录代码",
        "一次性代码", "一次性密码", "认证码", "verification code", "verify code", "login code",
        "sign in code", "signin code", "one-time code", "one time code", "passcode",
        "security code", "authentication code", "two-factor", "2fa", "otp"
    ]

    private static let authContextTerms = [
        "登录", "登陆", "验证", "认证", "账号", "账户", "login", "log in", "sign in",
        "signin", "signing in", "verify", "verification", "authenticate", "account"
    ]

    private static let businessNoiseTerms = [
        "订单", "订单号", "物流", "运单", "快递", "发票", "金额", "合计", "优惠", "促销",
        "折扣", "满减", "券", "order", "order no", "tracking", "shipment", "invoice",
        "amount", "total", "promo", "promotion", "coupon", "discount", "sale"
    ]

    private static let highRiskTerms = [
        "支付", "付款", "转账", "提现", "重置密码", "找回密码", "修改密码", "银行卡",
        "身份验证", "实名", "payment", "pay", "transfer", "withdraw", "reset password",
        "password reset", "bank card", "identity verification"
    ]

    public func containsKeyword(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return keywords.contains { lowercased.contains($0.lowercased()) }
            || Self.strongAuthTerms.contains { lowercased.contains($0) }
    }

    public func extract(from text: String) -> String? {
        let candidates = tokenCandidates(in: text, allowSeparatedDigits: true)
        guard !candidates.isEmpty else { return nil }

        let lowercased = text.lowercased()
        let scored = candidates.map { candidate in
            ScoredCandidate(
                candidate: candidate,
                score: legacyScore(candidate: candidate, in: lowercased)
            )
        }

        return scored
            .sorted(by: sortScoredCandidates)
            .first?
            .candidate
            .value
    }

    public func assessEmail(
        subject: String,
        body: String,
        sender: String? = nil
    ) -> VerificationCodeExtractionAssessment {
        let limitedBody = limitedEmailBody(body)
        let combined = "\(subject)\n\(limitedBody)"
        let lowerSubject = subject.lowercased()
        let lowerCombined = combined.lowercased()
        let candidates = uniqueCandidates(tokenCandidates(in: combined, allowSeparatedDigits: true))

        guard !candidates.isEmpty else {
            return VerificationCodeExtractionAssessment(
                code: nil,
                confidence: .low,
                candidateCount: 0,
                reasons: [],
                downgradeReasons: ["未发现合理候选码"]
            )
        }

        let subjectHasStrongAuth = containsAny(Self.strongAuthTerms, in: lowerSubject)
        let subjectHasAuthContext = subjectHasStrongAuth || containsAny(Self.authContextTerms, in: lowerSubject)
        let highRisk = containsAny(Self.highRiskTerms, in: lowerCombined)
        let senderScore = weakSenderScore(sender)

        let scored = candidates.map { candidate -> ScoredCandidate in
            var score = senderScore
            var reasons: [String] = []
            var downgrades: [String] = []

            if subjectHasStrongAuth {
                score += 82
                reasons.append("主题认证语义")
            } else if subjectHasAuthContext {
                score += 28
                reasons.append("主题弱登录语义")
            }

            if candidate.value.count == 6 {
                score += 10
                reasons.append("6位码形")
            } else if candidate.value.count == 4 || candidate.value.count == 8 {
                score += 6
                reasons.append("\(candidate.value.count)位码形")
            }

            if candidate.isSeparatedDigits {
                score -= 12
                downgrades.append("分隔数字需认证上下文")
            }

            let authProximity = proximityScore(
                candidate: candidate,
                text: lowerCombined,
                terms: Self.strongAuthTerms + Self.authContextTerms
            )
            if authProximity.score > 0 {
                score += authProximity.score
                reasons.append(authProximity.reason)
            }

            if matchesUseToSignIn(candidate: candidate, text: lowerCombined) {
                score += 95
                reasons.append("Use code to sign in")
            }

            let noisePenalty = proximityPenalty(
                candidate: candidate,
                text: lowerCombined,
                terms: Self.businessNoiseTerms
            )
            if noisePenalty > 0 {
                score -= noisePenalty
                downgrades.append("订单/物流/金额/促销语义")
            }

            if looksLikeDuration(candidate: candidate, in: lowerCombined) {
                score -= 85
                downgrades.append("疑似有效期数字")
            }
            if looksLikeDate(candidate: candidate, in: lowerCombined) {
                score -= 90
                downgrades.append("疑似日期")
            }

            if candidate.isSeparatedDigits && authProximity.score < 70 && !matchesUseToSignIn(candidate: candidate, text: lowerCombined) {
                score -= 65
                downgrades.append("分隔数字缺少明确认证语义")
            }

            return ScoredCandidate(candidate: candidate, score: score, reasons: reasons, downgradeReasons: downgrades)
        }.sorted(by: sortScoredCandidates)

        guard let top = scored.first else {
            return VerificationCodeExtractionAssessment(code: nil, confidence: .low, candidateCount: 0, reasons: [])
        }

        var confidence = confidence(for: top.score)
        var downgradeReasons = top.downgradeReasons
        let uniqueCount = candidates.count
        let hasAuthenticationSemantics = subjectHasAuthContext
            || top.reasons.contains(where: { $0.contains("认证") || $0.contains("登录") || $0.contains("sign in") || $0.contains("Use") || $0.contains("语义") })

        if subjectHasStrongAuth, uniqueCount == 1, top.score >= 92 {
            confidence = .high
        }

        if !hasAuthenticationSemantics {
            confidence = .low
            downgradeReasons.append("没有登录/认证语义")
        }

        if scored.count > 1, let second = scored.dropFirst().first, top.score - second.score <= 35 {
            confidence = minConfidence(confidence, .medium)
            downgradeReasons.append("多个候选分数接近")
        }

        if highRisk, confidence != .low {
            confidence = minConfidence(confidence, .medium)
            downgradeReasons.append("高风险页面/邮件语义")
        }

        if top.score < 55 {
            confidence = .low
        }

        if confidence == .low {
            return VerificationCodeExtractionAssessment(
                code: nil,
                confidence: .low,
                candidateCount: uniqueCount,
                reasons: top.reasons,
                downgradeReasons: Array(Set(downgradeReasons)).sorted()
            )
        }

        return VerificationCodeExtractionAssessment(
            code: top.candidate.value,
            confidence: confidence,
            candidateCount: uniqueCount,
            reasons: top.reasons,
            downgradeReasons: Array(Set(downgradeReasons)).sorted()
        )
    }

    private func tokenCandidates(in text: String, allowSeparatedDigits: Bool) -> [TokenCandidate] {
        var candidates: [TokenCandidate] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let tokenPattern = #"(?<![A-Za-z0-9])([A-Za-z0-9]{4,8})(?![A-Za-z0-9])"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            candidates += regex.matches(in: text, range: fullRange).compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                let tokenRange = match.range(at: 1)
                let value = nsText.substring(with: tokenRange)
                guard value.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
                return TokenCandidate(value: value, rawValue: value, range: tokenRange, isSeparatedDigits: false)
            }
        }

        guard allowSeparatedDigits else { return candidates }
        let separatedPattern = #"(?<!\d)(\d{2,4})[ -](\d{2,4})(?!\d)"#
        guard let separatedRegex = try? NSRegularExpression(pattern: separatedPattern) else {
            return candidates
        }
        candidates += separatedRegex.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let first = nsText.substring(with: match.range(at: 1))
            let second = nsText.substring(with: match.range(at: 2))
            let normalized = first + second
            guard (4...8).contains(normalized.count) else { return nil }
            return TokenCandidate(
                value: normalized,
                rawValue: nsText.substring(with: match.range(at: 0)),
                range: match.range(at: 0),
                isSeparatedDigits: true
            )
        }
        return candidates
    }

    private func limitedEmailBody(_ body: String) -> String {
        guard body.count > Self.maxEmailBodyCharacters else { return body }
        let half = Self.maxEmailBodyCharacters / 2
        return String(body.prefix(half)) + "\n" + String(body.suffix(half))
    }

    private func uniqueCandidates(_ candidates: [TokenCandidate]) -> [TokenCandidate] {
        var seen = Set<String>()
        var result: [TokenCandidate] = []
        for candidate in candidates where !seen.contains(candidate.value) {
            seen.insert(candidate.value)
            result.append(candidate)
        }
        return result
    }

    private func legacyScore(candidate: TokenCandidate, in text: String) -> Int {
        var score = 0
        let nsText = text as NSString

        for keyword in keywords + Self.strongAuthTerms {
            let keyword = keyword.lowercased()
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let found = nsText.range(of: keyword, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }

                let distance: Int
                if found.location <= candidate.range.location {
                    distance = candidate.range.location - (found.location + found.length)
                    if distance >= 0 && distance <= 32 {
                        score += 110 - distance
                    }
                } else {
                    distance = found.location - (candidate.range.location + candidate.range.length)
                    if distance >= 0 && distance <= 20 {
                        score += 45 - distance
                    }
                }

                let nextLocation = found.location + max(found.length, 1)
                if nextLocation >= nsText.length { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }

        if candidate.value.count == 6 {
            score += 8
        } else if candidate.value.count == 4 || candidate.value.count == 8 {
            score += 4
        }

        if looksLikeDuration(candidate: candidate, in: text) {
            score -= 80
        }

        return score
    }

    private func proximityScore(candidate: TokenCandidate, text: String, terms: [String]) -> (score: Int, reason: String) {
        let nsText = text as NSString
        var best = 0
        var bestTerm = ""
        for term in terms {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let found = nsText.range(of: term, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                let distanceBefore = candidate.range.location - (found.location + found.length)
                let distanceAfter = found.location - (candidate.range.location + candidate.range.length)
                if distanceBefore >= 0, distanceBefore <= 64 {
                    let value = 122 - min(distanceBefore, 60)
                    if value > best {
                        best = value
                        bestTerm = term
                    }
                } else if distanceAfter >= 0, distanceAfter <= 36 {
                    let value = 62 - min(distanceAfter, 36)
                    if value > best {
                        best = value
                        bestTerm = term
                    }
                }
                let nextLocation = found.location + max(found.length, 1)
                if nextLocation >= nsText.length { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }
        return best > 0 ? (best, "靠近认证语义:\(bestTerm)") : (0, "")
    }

    private func proximityPenalty(candidate: TokenCandidate, text: String, terms: [String]) -> Int {
        let nsText = text as NSString
        var penalty = 0
        for term in terms {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let found = nsText.range(of: term, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                let distance = min(
                    abs(candidate.range.location - (found.location + found.length)),
                    abs(found.location - (candidate.range.location + candidate.range.length))
                )
                if distance <= 36 {
                    penalty = max(penalty, 70 - min(distance, 36))
                } else if distance <= 96 {
                    penalty = max(penalty, 22)
                }
                let nextLocation = found.location + max(found.length, 1)
                if nextLocation >= nsText.length { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }
        return penalty
    }

    private func matchesUseToSignIn(candidate: TokenCandidate, text: String) -> Bool {
        let raw = NSRegularExpression.escapedPattern(for: candidate.rawValue.lowercased())
        let patterns = [
            #"use\s+\#(raw)\s+to\s+(?:sign\s*in|log\s*in|verify)"#,
            #"\#(raw)\s+(?:is\s+)?(?:your\s+)?(?:login|sign\s*in|verification|security)\s+code"#
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }

    private func looksLikeDuration(candidate: TokenCandidate, in text: String) -> Bool {
        let nsText = text as NSString
        let start = candidate.range.location + candidate.range.length
        guard start < nsText.length else { return false }
        let length = min(16, nsText.length - start)
        let suffix = nsText.substring(with: NSRange(location: start, length: length)).lowercased()
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSuffix.hasPrefix("分钟")
            || trimmedSuffix.hasPrefix("min")
            || trimmedSuffix.hasPrefix("小时")
            || trimmedSuffix.hasPrefix("seconds")
            || trimmedSuffix.hasPrefix("秒")
    }

    private func looksLikeDate(candidate: TokenCandidate, in text: String) -> Bool {
        let value = candidate.value
        if value.count == 8, value.hasPrefix("20") || value.hasPrefix("19") {
            return true
        }
        let nsText = text as NSString
        let start = max(0, candidate.range.location - 4)
        let end = min(nsText.length, candidate.range.location + candidate.range.length + 4)
        let context = nsText.substring(with: NSRange(location: start, length: end - start))
        return context.contains("年") || context.contains("月") || context.contains("日") || context.contains("/")
    }

    private func containsAny(_ terms: [String], in text: String) -> Bool {
        terms.contains { text.contains($0.lowercased()) }
    }

    private func weakSenderScore(_ sender: String?) -> Int {
        guard let sender = sender?.lowercased(), !sender.isEmpty else { return 0 }
        let weakTerms = ["no-reply", "noreply", "security", "account"]
        return weakTerms.contains(where: { sender.contains($0) }) ? 8 : 0
    }

    private func confidence(for score: Int) -> VerificationCodeConfidence {
        if score >= 120 { return .high }
        if score >= 62 { return .medium }
        return .low
    }

    private func minConfidence(
        _ lhs: VerificationCodeConfidence,
        _ rhs: VerificationCodeConfidence
    ) -> VerificationCodeConfidence {
        order(lhs) < order(rhs) ? lhs : rhs
    }

    private func order(_ confidence: VerificationCodeConfidence) -> Int {
        switch confidence {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    private func sortScoredCandidates(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.score == rhs.score {
            if lhs.candidate.value.count == rhs.candidate.value.count {
                return lhs.candidate.range.location < rhs.candidate.range.location
            }
            return lhs.candidate.value.count > rhs.candidate.value.count
        }
        return lhs.score > rhs.score
    }
}

private struct TokenCandidate {
    let value: String
    let rawValue: String
    let range: NSRange
    let isSeparatedDigits: Bool
}

private struct ScoredCandidate {
    let candidate: TokenCandidate
    let score: Int
    var reasons: [String] = []
    var downgradeReasons: [String] = []
}
