import Testing
@testable import SmsCodeCore

struct VerificationRequestButtonMatcherTests {
    @Test func matchesCommonChineseRequestCodeButtons() {
        let matcher = VerificationRequestButtonMatcher()

        #expect(matcher.isRequestCodeButton(role: "AXButton", title: "获取验证码", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXStaticText", title: "发送短信验证码", description: nil, value: nil))
    }

    @Test func matchesCommonEnglishRequestCodeButtons() {
        let matcher = VerificationRequestButtonMatcher()

        #expect(matcher.isRequestCodeButton(role: "AXButton", title: "Send code", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXLink", title: "Get verification code", description: nil, value: nil))
    }

    @Test func rejectsLoginAndThirdPartyButtons() {
        let matcher = VerificationRequestButtonMatcher()

        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "登录", description: nil, value: nil))
        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "微信登录", description: nil, value: nil))
    }

    @Test func matchesExpandedStrongRequestCodeWords() {
        let matcher = VerificationRequestButtonMatcher()

        #expect(matcher.isRequestCodeButton(role: "AXButton", title: "获取动态码", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXButton", title: "发送校验码", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXButton", title: "免费获取验证码", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXStaticText", title: "重新获取验证码", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXButton", title: "Send SMS", description: nil, value: nil))
        #expect(matcher.isRequestCodeButton(role: "AXText", title: "Send verification code", description: nil, value: nil))
    }

    @Test func rejectsWeakNextButtonsAndCountdownStates() {
        let matcher = VerificationRequestButtonMatcher()

        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "下一步", description: nil, value: nil))
        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "Continue", description: nil, value: nil))
        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "重新获取", description: nil, value: nil))
        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "60s 后重发", description: nil, value: nil))
        #expect(!matcher.isRequestCodeButton(role: "AXButton", title: "已发送", description: nil, value: nil))
    }
}
