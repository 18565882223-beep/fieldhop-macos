import Foundation
import Testing
@testable import SmsCodeCore

struct EmailVerificationTests {
    private let selector = EmailVerificationCodeSelector()

    @Test func highConfidenceWhenSubjectHasKeywordAndBodyHasSingleCodeWithoutKeyword() throws {
        let message = makeMessage(subject: "登录验证码", body: "482731")
        let assessment = selector.assess(message: message)

        #expect(assessment.confidence == .high)
        #expect(selector.candidate(from: message, now: Date())?.code == "482731")
    }

    @Test func highConfidenceWhenBodyHasKeywordAndSubjectIsGeneric() {
        let message = makeMessage(subject: "Your account notice", body: "Your one-time code is A7B9C2.")
        let assessment = selector.assess(message: message)

        #expect(assessment.confidence == .high)
        #expect(selector.candidate(from: message)?.code == "A7B9C2")
    }

    @Test func highConfidenceForLongBodyEndingWithLoginCode() {
        let longBody = String(repeating: "这是一段登录说明文字，用于测试长正文解析。", count: 700)
            + "\n本次登录代码：482731"
        let message = makeMessage(subject: "通知", body: longBody)

        #expect(selector.assess(message: message).confidence == .high)
        #expect(selector.candidate(from: message)?.code == "482731")
    }

    @Test func highConfidenceForEnglishUseCodeToSignIn() {
        let message = makeMessage(subject: "Notification", body: "Use 482731 to sign in to your account.")

        #expect(selector.assess(message: message).confidence == .high)
        #expect(selector.candidate(from: message)?.code == "482731")
    }

    @Test func supportsFourSixEightAlphanumericAndSeparatedCodes() {
        let samples = [
            (makeMessage(subject: "验证码", body: "请使用 7391 完成登录"), "7391"),
            (makeMessage(subject: "普通通知", body: "登录验证码为 739516"), "739516"),
            (makeMessage(subject: "Verify your account", body: "Verification code: 12345678"), "12345678"),
            (makeMessage(subject: "Login", body: "Your login code is A7B9C2"), "A7B9C2"),
            (makeMessage(subject: "登录验证", body: "验证码 123-456，请勿泄露"), "123456"),
            (makeMessage(subject: "登录验证", body: "验证码 123 456，请勿泄露"), "123456")
        ]

        for (message, expected) in samples {
            #expect(selector.assess(message: message).confidence == .high)
            #expect(selector.candidate(from: message)?.code == expected)
        }
    }

    @Test func multipleCloseCandidatesDowngradeToMedium() {
        let message = makeMessage(
            subject: "登录验证码",
            body: "验证码 111111 或安全码 222222 均出现在邮件中。"
        )
        let assessment = selector.assess(message: message)

        #expect(assessment.confidence == .medium)
        #expect(assessment.downgradeReasons.contains("多个候选分数接近"))
        #expect(selector.candidate(from: message) == nil)
    }

    @Test func businessNoiseIsLowWithoutAuthenticationSemantics() {
        let invalid = [
            makeMessage(subject: "订单 123456 已创建", body: "您的订单 123456 已创建。"),
            makeMessage(subject: "物流通知", body: "运单号 12345678 正在派送。"),
            makeMessage(subject: "发票金额", body: "发票金额 123456 元。"),
            makeMessage(subject: "促销优惠", body: "优惠码 123456 今日可用。"),
            makeMessage(subject: "活动日期", body: "活动日期 20260712。")
        ]

        for message in invalid {
            let assessment = selector.assess(message: message)
            #expect(assessment.confidence == .low)
            #expect(selector.candidate(from: message) == nil)
        }
    }

    @Test func highRiskAuthenticationDowngradesToManualConfirmation() {
        let messages = [
            makeMessage(subject: "支付身份验证", body: "本次验证码 482731，请确认付款。"),
            makeMessage(subject: "Transfer security code", body: "Your security code is 482731 for this transfer."),
            makeMessage(subject: "重置密码", body: "验证码 482731 用于重置密码。")
        ]

        for message in messages {
            let assessment = selector.assess(message: message)
            #expect(assessment.confidence == .medium)
            #expect(assessment.downgradeReasons.contains("高风险页面/邮件语义"))
            #expect(selector.candidate(from: message) == nil)
        }
    }

    @Test func isolatedNumberWithoutAuthenticationNeverAutoFills() {
        let message = makeMessage(subject: "普通通知", body: "您的号码是 482731。")

        #expect(selector.assess(message: message).confidence == .low)
        #expect(selector.candidate(from: message) == nil)
    }

    @Test func diagnosticSummaryIsSanitizedAndShowsManualConfirmation() {
        let diagnostic = EmailPollDiagnostic(
            lastPollSucceeded: true,
            discoveredUIDCount: 1,
            fetchSucceededCount: 1,
            mimeSucceededCount: 1,
            mediumConfidenceCount: 1,
            lastExtractionSummary: "中置信，候选=1，理由=靠近认证语义:security code，降级=高风险页面/邮件语义"
        )

        #expect(diagnostic.summaryText.contains("发现疑似验证码，需手动确认"))
        #expect(!diagnostic.summaryText.contains("482731"))
    }

    @Test func strictFillGateRequiresChromeFocusedVerificationAndHost() {
        let gate = EmailFillGate()
        #expect(gate.decide(isPaused: false, frontmostBundleIdentifier: "com.apple.Safari", hasFocusedElement: true, isVerificationField: true, targetHost: "example.com") == .clipboardOnly(reason: "当前前台不是 Chrome"))
        #expect(gate.decide(isPaused: false, frontmostBundleIdentifier: "com.google.Chrome", hasFocusedElement: true, isVerificationField: false, targetHost: "example.com") == .clipboardOnly(reason: "当前焦点不是验证码框"))
        #expect(gate.decide(isPaused: false, frontmostBundleIdentifier: "com.google.Chrome", hasFocusedElement: true, isVerificationField: true, targetHost: nil) == .clipboardOnly(reason: "无法确认当前网页 host"))
        #expect(gate.decide(isPaused: false, frontmostBundleIdentifier: "com.google.Chrome", hasFocusedElement: true, isVerificationField: true, targetHost: "example.com") == .fill(targetHost: "example.com"))
    }

    private func makeMessage(subject: String, body: String, uid: UInt64 = 1) -> EmailVerificationMessage {
        EmailVerificationMessage(
            accountID: UUID(),
            uid: uid,
            date: Date(timeIntervalSince1970: 0),
            subject: subject,
            body: body
        )
    }
}
