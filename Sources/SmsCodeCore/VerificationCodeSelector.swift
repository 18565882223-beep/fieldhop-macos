import Foundation

public struct VerificationCodeSelector {
    public let extractor: VerificationCodeExtractor
    public let timeWindow: TimeInterval

    public init(
        extractor: VerificationCodeExtractor = VerificationCodeExtractor(),
        timeWindow: TimeInterval = 180
    ) {
        self.extractor = extractor
        self.timeWindow = timeWindow
    }

    public func latestCode(in messages: [SMSMessage], now: Date = Date()) -> DetectedVerificationCode? {
        messages
            .filter { message in
                message.date <= now
                    && now.timeIntervalSince(message.date) <= timeWindow
                    && extractor.containsKeyword(message.text)
            }
            .sorted { $0.date > $1.date }
            .compactMap { message in
                extractor.extract(from: message.text).map {
                    DetectedVerificationCode(code: $0, message: message)
                }
            }
            .first
    }
}
