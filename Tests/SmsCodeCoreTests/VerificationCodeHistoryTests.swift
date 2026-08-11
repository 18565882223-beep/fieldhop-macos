import Foundation
import Testing
@testable import SmsCodeCore

struct VerificationCodeHistoryTests {
    @Test func keepsNewestFiveCodesOnly() {
        var history = VerificationCodeHistory(maxCount: 5)

        for index in 0..<7 {
            history.record(code: "10000\(index)", date: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        #expect(history.items.map(\.code) == ["100006", "100005", "100004", "100003", "100002"])
    }

    @Test func duplicateCodeMovesToFront() {
        var history = VerificationCodeHistory(maxCount: 5)

        history.record(code: "111111", date: Date(timeIntervalSince1970: 1))
        history.record(code: "222222", date: Date(timeIntervalSince1970: 2))
        history.record(code: "111111", date: Date(timeIntervalSince1970: 3))

        #expect(history.items.map(\.code) == ["111111", "222222"])
        #expect(history.items[0].date == Date(timeIntervalSince1970: 3))
    }

    @Test func outOfBoundsLookupReturnsNil() {
        let history = VerificationCodeHistory(maxCount: 5)

        #expect(history.code(at: 0) == nil)
    }
}
