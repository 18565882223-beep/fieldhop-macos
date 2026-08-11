import Foundation
import Testing
@testable import SmsCodeCore

struct StressTests {
    @Test func selectsLatestCodeFromLargeMessageBatch() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let messages = (0..<10_000).map { index in
            SMSMessage(
                text: "普通通知 \(index)",
                date: now.addingTimeInterval(-Double(index % 170)),
                service: "SMS"
            )
        } + [
            SMSMessage(text: "验证码987654，5分钟内有效", date: now.addingTimeInterval(-1), service: "SMS")
        ]

        let selector = VerificationCodeSelector()
        #expect(selector.latestCode(in: messages, now: now)?.code == "987654")
    }

    @Test func extractsCodesFromManySamples() {
        let extractor = VerificationCodeExtractor()

        for index in 0..<2_000 {
            let code = String(format: "%06d", index)
            #expect(extractor.extract(from: "验证码\(code)，请勿泄露。") == code)
        }
    }
}
