import Foundation
import Testing
@testable import SmsCodeCore

struct AutomationPolicyTests {
    @Test func trustedModeAllowsDefaultBilibiliHost() {
        let policy = AutomationSafetyPolicy()
        let settings = AutomationSettings(autoClickMode: .trustedOnly)
        let context = AutomationTargetContext(urlString: "space.bilibili.com/50548992")

        #expect(policy.decision(settings: settings, context: context).isAllowed)
    }

    @Test func trustedModeRejectsUnknownHost() {
        let policy = AutomationSafetyPolicy()
        let settings = AutomationSettings(autoClickMode: .trustedOnly)
        let context = AutomationTargetContext(urlString: "example.com/login")

        #expect(!policy.decision(settings: settings, context: context).isAllowed)
    }

    @Test func aggressiveModeStillBlocksRiskWords() {
        let policy = AutomationSafetyPolicy()
        let settings = AutomationSettings(autoClickMode: .aggressive)
        let context = AutomationTargetContext(
            urlString: "trusted.example/login",
            pageText: "请输入验证码以修改密码"
        )

        let decision = policy.decision(settings: settings, context: context)
        #expect(!decision.isAllowed)
        #expect(decision.reason == "页面含高风险词，禁止自动操作")
    }

    @Test func hostMatchingAcceptsSubdomains() {
        let policy = AutomationSafetyPolicy()
        let settings = AutomationSettings(
            autoClickMode: .trustedOnly,
            allowedHosts: ["example.com"]
        )
        let context = AutomationTargetContext(urlString: "https://login.example.com/sms")

        #expect(policy.decision(settings: settings, context: context).isAllowed)
    }

    @Test func offModeAlwaysRejectsSafePages() {
        let policy = AutomationSafetyPolicy()
        let settings = AutomationSettings(autoClickMode: .off)
        let context = AutomationTargetContext(urlString: "https://space.bilibili.com/")

        #expect(!policy.decision(settings: settings, context: context).isAllowed)
    }

    @Test func separatesPhoneFillAndLoginPermissionsByAction() {
        let policy = AutomationSafetyPolicy()
        let settings = AutomationSettings(autoClickMode: .trustedOnly, allowedHosts: ["example.com"])
        let trusted = AutomationTargetContext(urlString: "https://example.com/login")
        let unknown = AutomationTargetContext(urlString: "https://unknown.test/login")

        #expect(policy.decision(settings: settings, context: trusted, permission: .fillPhone).isAllowed)
        #expect(policy.decision(settings: settings, context: trusted, permission: .requestVerificationCode).isAllowed)
        #expect(policy.decision(settings: settings, context: trusted, permission: .clickLogin).isAllowed)
        #expect(!policy.decision(settings: settings, context: unknown, permission: .fillPhone).isAllowed)
    }

    @Test func decodesOldAutomationSettingsWithAgreementEnabledByDefault() throws {
        let oldJSON = """
        {
          "autoClickMode": "trustedOnly",
          "allowedBundleIdentifiers": [],
          "allowedHosts": ["example.com"]
        }
        """

        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(oldJSON.utf8))

        #expect(settings.autoCheckRequiredAgreement)
        #expect(settings.allowedHosts == ["example.com"])
    }
}
