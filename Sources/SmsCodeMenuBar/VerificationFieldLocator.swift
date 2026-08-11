import AppKit
import Foundation
import SmsCodeCore

@MainActor
struct VerificationFieldLocator {
    let accessibilityReader: AccessibilityReader
    let classifier: FocusedElementClassifier

    func cachedField(in session: LoginAutomationSession) -> AXUIElement? {
        guard let field = session.cachedVerificationField else { return nil }
        return accessibilityReader.verificationSnapshot(of: field, classifier: classifier) == nil ? nil : field
    }

    func fieldNearSessionAnchor(_ session: LoginAutomationSession) -> AXUIElement? {
        accessibilityReader.findVerificationFieldNearAnchor(
            session.phoneFieldAnchor,
            classifier: classifier
        )
    }

    func fieldInTargetProcess(_ session: LoginAutomationSession) -> AXUIElement? {
        accessibilityReader.findVerificationFieldForIncomingCode(
            inProcessID: session.targetProcessID,
            classifier: classifier
        )
    }

    func fieldInCurrentContext() -> AXUIElement? {
        accessibilityReader.findVerificationFieldForIncomingCode(classifier: classifier)
    }
}
