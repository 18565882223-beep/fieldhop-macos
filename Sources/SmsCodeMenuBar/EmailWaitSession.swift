import Foundation

struct EmailWaitSession: Equatable {
    let accountID: UUID
    let startedAt: Date
    let expiresAt: Date

    init(accountID: UUID, now: Date = Date(), durationMinutes: Int) {
        self.accountID = accountID
        startedAt = now
        expiresAt = now.addingTimeInterval(TimeInterval(min(max(durationMinutes, 5), 15) * 60))
    }

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}
