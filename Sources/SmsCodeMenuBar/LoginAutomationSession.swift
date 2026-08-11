import AppKit
import Foundation

struct LoginAutomationSession {
    static let defaultLifetime: TimeInterval = 5 * 60

    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let targetProcessID: pid_t?
    let targetBundleIdentifier: String?
    let targetHost: String?
    let phoneFieldAnchor: AXUIElement?
    var cachedVerificationField: AXUIElement?

    init(
        now: Date = Date(),
        lifetime: TimeInterval = Self.defaultLifetime,
        targetProcessID: pid_t?,
        targetBundleIdentifier: String?,
        targetHost: String?,
        phoneFieldAnchor: AXUIElement?
    ) {
        self.id = UUID()
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(lifetime)
        self.targetProcessID = targetProcessID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetHost = targetHost
        self.phoneFieldAnchor = phoneFieldAnchor
        self.cachedVerificationField = nil
    }

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    var summary: String {
        [
            "id=\(id.uuidString)",
            "pid=\(targetProcessID.map(String.init) ?? "nil")",
            "bundle=\(targetBundleIdentifier ?? "nil")",
            "host=\(targetHost ?? "nil")",
            "hasAnchor=\(phoneFieldAnchor != nil)",
            "hasCachedField=\(cachedVerificationField != nil)"
        ].joined(separator: " ")
    }
}
