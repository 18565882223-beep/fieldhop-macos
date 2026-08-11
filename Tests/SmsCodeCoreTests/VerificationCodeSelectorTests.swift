import Foundation
import Testing
@testable import SmsCodeCore

struct VerificationCodeSelectorTests {
    @Test func selectsNewestKeywordMessageInsideWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let selector = VerificationCodeSelector(timeWindow: 180)
        let messages = [
            SMSMessage(text: "验证码111111", date: now.addingTimeInterval(-30), service: "SMS"),
            SMSMessage(text: "验证码222222", date: now.addingTimeInterval(-10), service: "SMS")
        ]

        #expect(selector.latestCode(in: messages, now: now)?.code == "222222")
    }

    @Test func respectsTimeWindowBoundaries() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let selector = VerificationCodeSelector(timeWindow: 180)
        let messages = [
            SMSMessage(text: "验证码170170", date: now.addingTimeInterval(-170), service: "SMS"),
            SMSMessage(text: "验证码190190", date: now.addingTimeInterval(-190), service: "SMS")
        ]

        #expect(selector.latestCode(in: messages, now: now)?.code == "170170")
    }

    @Test func ignoresOldMessages() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let selector = VerificationCodeSelector(timeWindow: 180)
        let messages = [
            SMSMessage(text: "验证码111111", date: now.addingTimeInterval(-181), service: "SMS")
        ]

        #expect(selector.latestCode(in: messages, now: now) == nil)
    }

    @Test func ignoresMessagesWithoutKeyword() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let selector = VerificationCodeSelector(timeWindow: 180)
        let messages = [
            SMSMessage(text: "您的订单号为 123456", date: now.addingTimeInterval(-10), service: "SMS")
        ]

        #expect(selector.latestCode(in: messages, now: now) == nil)
    }

    @Test func ignoresMarketingDeliveryAndAmountMessages() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let selector = VerificationCodeSelector(timeWindow: 180)
        let messages = [
            SMSMessage(text: "【快递】取件码 8821，货架 03。", date: now.addingTimeInterval(-10), service: "SMS"),
            SMSMessage(text: "【银行】消费人民币 128.50 元，余额 3000.00 元。", date: now.addingTimeInterval(-9), service: "SMS"),
            SMSMessage(text: "【商家】优惠码 6666 今日可用，满100减20。", date: now.addingTimeInterval(-8), service: "SMS"),
            SMSMessage(text: "【航旅】订单号 123456，航班 9876 已出票。", date: now.addingTimeInterval(-7), service: "SMS")
        ]

        #expect(selector.latestCode(in: messages, now: now) == nil)
    }
}
