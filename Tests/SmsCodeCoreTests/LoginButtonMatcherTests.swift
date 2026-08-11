import Testing
@testable import SmsCodeCore

struct LoginButtonMatcherTests {
    @Test func matchesCommonLoginButtons() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isLoginButton(role: "AXButton", title: "登录", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "登 录", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "立即登录", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "Login", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "Log in", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "Sign in", description: nil, value: nil))
    }

    @Test func matchesLoginRegisterCombo() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isLoginButton(role: "AXButton", title: "登录/注册", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "登录或注册", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "Login / Register", description: nil, value: nil))
    }

    @Test func matchesGeneralSubmitButtons() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isLoginButton(role: "AXButton", title: "确定", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "下一步", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "Submit", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "Go", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: "发送", description: nil, value: nil))
    }

    @Test func matchesLinkRoleButtons() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isLoginButton(role: "AXLink", title: "登录", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXLink", title: "登录/注册", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXLink", title: "Login", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXLink", title: "Sign in", description: nil, value: nil))
    }

    @Test func matchesMenuItemRoleButtons() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isLoginButton(role: "AXMenuItem", title: "登录", description: nil, value: nil))
        #expect(matcher.isLoginButton(role: "AXMenuItem", title: "Login", description: nil, value: nil))
    }

    @Test func rejectsNonActionableRoles() {
        let matcher = LoginButtonMatcher()

        #expect(!matcher.isLoginButton(role: "AXStaticText", title: "登录", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXGroup", title: "登录", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXImage", title: "登录", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: nil, title: "登录", description: nil, value: nil))
    }

    @Test func rejectsPureRegisterButtons() {
        let matcher = LoginButtonMatcher()

        #expect(!matcher.isLoginButton(role: "AXButton", title: "注册", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXButton", title: "立即注册", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXButton", title: "Sign up", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXLink", title: "注册", description: nil, value: nil))
    }

    @Test func blacklistsDangerousButtons() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isBlacklisted(title: "取消", description: nil, value: nil))
        #expect(matcher.isBlacklisted(title: "注册", description: nil, value: nil))
        #expect(matcher.isBlacklisted(title: "Close", description: nil, value: nil))
        #expect(matcher.isBlacklisted(title: "退出", description: nil, value: nil))
        #expect(matcher.isBlacklisted(title: "清空", description: nil, value: nil))
    }

    @Test func doesNotBlacklistLoginRegisterCombo() {
        let matcher = LoginButtonMatcher()

        #expect(!matcher.isBlacklisted(title: "登录/注册", description: nil, value: nil))
        #expect(!matcher.isBlacklisted(title: "Login / Register", description: nil, value: nil))
    }

    @Test func doesNotBlacklistLoginButtons() {
        let matcher = LoginButtonMatcher()

        #expect(!matcher.isBlacklisted(title: "登录", description: nil, value: nil))
        #expect(!matcher.isBlacklisted(title: "Login", description: nil, value: nil))
    }

    @Test func matchesByDescriptionOrValueWhenTitleEmpty() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isLoginButton(role: "AXButton", title: nil, description: "登录按钮", value: nil))
        #expect(matcher.isLoginButton(role: "AXButton", title: nil, description: nil, value: "登录"))
        #expect(matcher.isLoginButton(role: "AXLink", title: nil, description: "Login", value: nil))
    }

    @Test func matchesBilibiliStaticLoginRegisterText() {
        let matcher = LoginButtonMatcher()

        #expect(matcher.isClickableLoginText(title: nil, description: nil, value: "登录/注册"))
        #expect(matcher.isClickableLoginText(title: "登录/注册", description: nil, value: nil))
    }

    @Test func rejectsResendCodeText() {
        let matcher = LoginButtonMatcher()

        #expect(!matcher.isLoginButton(role: "AXButton", title: "重新发送", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXButton", title: "发送验证码", description: nil, value: nil))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "重新发送"))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "发送验证码"))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "验证码"))
    }

    @Test func rejectsThirdPartyLoginButtons() {
        let matcher = LoginButtonMatcher()

        #expect(!matcher.isLoginButton(role: "AXButton", title: "微信登录", description: nil, value: nil))
        #expect(!matcher.isLoginButton(role: "AXButton", title: nil, description: "抖音登录", value: nil))
        #expect(!matcher.isLoginButton(role: "AXPopUpButton", title: "员工登录", description: nil, value: nil))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "其它登录方式"))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "扫描二维码登录"))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "密码登录"))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "短信登录"))
        #expect(!matcher.isClickableLoginText(title: nil, description: nil, value: "登录或完成注册即代表你同意"))
    }
}
