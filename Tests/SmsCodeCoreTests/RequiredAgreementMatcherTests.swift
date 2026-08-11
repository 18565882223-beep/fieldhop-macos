import Testing
@testable import SmsCodeCore

struct RequiredAgreementMatcherTests {
    @Test func matchesRequiredAgreementCheckboxes() {
        let matcher = RequiredAgreementMatcher()

        #expect(matcher.isAgreementCheckbox(
            role: "AXCheckBox",
            title: "我已阅读并同意用户协议和隐私政策",
            description: nil,
            value: "0",
            context: nil
        ))
        #expect(matcher.isAgreementCheckbox(
            role: "AXCheckBox",
            title: nil,
            description: "I agree to the Terms and Privacy Policy",
            value: "0",
            context: nil
        ))
    }

    @Test func rejectsMarketingRememberMeAndNonCheckboxControls() {
        let matcher = RequiredAgreementMatcher()

        #expect(!matcher.isAgreementCheckbox(
            role: "AXCheckBox",
            title: "同意接收营销短信和促销信息",
            description: nil,
            value: "0",
            context: nil
        ))
        #expect(!matcher.isAgreementCheckbox(
            role: "AXCheckBox",
            title: "记住我，自动登录",
            description: nil,
            value: "0",
            context: nil
        ))
        #expect(!matcher.isAgreementCheckbox(
            role: "AXStaticText",
            title: "我已阅读并同意用户协议",
            description: nil,
            value: nil,
            context: nil
        ))
    }

    @Test func doesNotRejectAgreementBecausePageBackgroundMentionsAuthorization() {
        let matcher = RequiredAgreementMatcher()

        #expect(matcher.isAgreementCheckbox(
            role: "AXCheckBox",
            title: "已阅读并同意 用户协议、隐私政策",
            description: nil,
            value: "0",
            context: "登录 扣子账号页面 已阅读并同意 用户协议 隐私政策 把个人电脑的文件授权给 Agent"
        ))

        #expect(!matcher.isAgreementCheckbox(
            role: "AXCheckBox",
            title: "第三方授权登录",
            description: nil,
            value: "0",
            context: "用户协议 隐私政策"
        ))
    }
}
