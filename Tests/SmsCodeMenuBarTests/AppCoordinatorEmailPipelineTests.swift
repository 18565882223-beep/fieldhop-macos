import AppKit
import Foundation
import Testing
@testable import SmsCodeCore
@testable import SmsCodeMenuBar

struct AppCoordinatorEmailPipelineTests {
    @Test @MainActor func emailCandidateOutsideWaitSessionIsIgnored() async throws {
        let coordinator = AppCoordinator(environment: [
            "SMS_CODE_DISABLE_LAUNCH_AT_LOGIN": "1",
            "SMS_CODE_EMAIL_FORM_UI_TEST": "1"
        ])
        let accountID = UUID()
        let code = "739516"
        let candidate = VerificationCodeCandidate(
            code: code,
            date: Date().addingTimeInterval(-1),
            source: .email(accountID: accountID, uid: 109)
        )

        coordinator.handleEmailVerificationCandidate(candidate)

        #expect(coordinator.recentCode == nil)
    }

    @Test @MainActor func emailCandidateNeedsActiveWaitSession() {
        let coordinator = AppCoordinator(environment: [
            "SMS_CODE_DISABLE_LAUNCH_AT_LOGIN": "1",
            "SMS_CODE_EMAIL_FORM_UI_TEST": "1"
        ])
        let context = AutomationTargetContext(
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Chrome",
            urlString: "https://example.com/reset-password",
            title: "重置密码",
            pageText: "请输入验证码完成身份验证"
        )

        coordinator.handleEmailVerificationCandidate(
            VerificationCodeCandidate(
                code: "482731",
                date: Date().addingTimeInterval(-1),
                source: .email(accountID: UUID(), uid: 110)
            )
        )

        #expect(coordinator.recentCode == nil)
        #expect(context.title == "重置密码")
    }
}
