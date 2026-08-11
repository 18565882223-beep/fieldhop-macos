import Foundation
import Testing
@testable import SmsCodeMenuBar

struct EmailWaitSessionTests {
    @Test func expiresAfterConfiguredDuration() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let session = EmailWaitSession(accountID: UUID(), now: now, durationMinutes: 5)
        #expect(!session.isExpired(now: now.addingTimeInterval(299)))
        #expect(session.isExpired(now: now.addingTimeInterval(300)))
    }

    @Test func clampsConfiguredDurationToSupportedRange() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let short = EmailWaitSession(accountID: UUID(), now: now, durationMinutes: 1)
        let long = EmailWaitSession(accountID: UUID(), now: now, durationMinutes: 30)
        #expect(short.expiresAt == now.addingTimeInterval(300))
        #expect(long.expiresAt == now.addingTimeInterval(900))
    }
}
