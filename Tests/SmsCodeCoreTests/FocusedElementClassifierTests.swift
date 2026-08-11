import Testing
@testable import SmsCodeCore

struct FocusedElementClassifierTests {
    @Test func onlyTypesIntoVerificationFieldAmongCommonFields() {
        let classifier = FocusedElementClassifier()
        let verificationField = FocusedElementSnapshot(
            role: "AXTextField",
            placeholder: "请输入验证码",
            value: ""
        )
        let searchField = FocusedElementSnapshot(
            role: "AXSearchField",
            placeholder: "搜索",
            value: "",
            width: 420
        )
        let bodyField = FocusedElementSnapshot(
            role: "AXTextArea",
            placeholder: "输入正文",
            value: "",
            width: 640
        )
        let addressBar = FocusedElementSnapshot(
            role: "AXTextField",
            title: "Address and search bar",
            value: "",
            width: 760
        )

        #expect(classifier.isStrongVerificationField(verificationField))
        #expect(!classifier.isStrongVerificationField(searchField))
        #expect(!classifier.isStrongVerificationField(bodyField))
        #expect(!classifier.isStrongVerificationField(addressBar))
    }

    @Test func acceptsOtpGridContainerWithVerificationContext() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXGroup",
            value: "",
            width: 96,
            context: "输入 6 位验证码 验证码已发送至手机"
        )

        #expect(classifier.isStrongVerificationField(snapshot))
    }

    @Test func acceptsOtpGridContainerWithVerificationKeywordOnly() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXGroup",
            value: "",
            width: 96,
            context: "验证码"
        )

        #expect(classifier.isStrongVerificationField(snapshot))
    }

    @Test func rejectsWindowAsStrongFieldButAllowsVerificationContextPaste() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXWindow",
            context: "输入 6 位验证码 验证码已发送至手机"
        )

        #expect(!classifier.isStrongVerificationField(snapshot))
        #expect(classifier.shouldPasteInVerificationContext(snapshot))
    }

    @Test func rejectsSearchAndBodyFieldsForContextPaste() {
        let classifier = FocusedElementClassifier()
        let searchField = FocusedElementSnapshot(
            role: "AXSearchField",
            placeholder: "搜索",
            value: "",
            width: 420,
            context: "输入 6 位验证码"
        )
        let bodyField = FocusedElementSnapshot(
            role: "AXTextArea",
            placeholder: "输入正文",
            value: "",
            width: 640,
            context: "输入 6 位验证码"
        )

        #expect(!classifier.shouldPasteInVerificationContext(searchField))
        #expect(!classifier.shouldPasteInVerificationContext(bodyField))
    }

    @Test func acceptsSegmentedOtpTextInputWithoutKeyword() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            value: "",
            width: 42,
            siblingTextInputCount: 6
        )

        #expect(classifier.isStrongVerificationField(snapshot))
    }

    @Test func rejectsButtonEvenWithVerificationContext() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXButton",
            title: "帮助",
            context: "输入 6 位验证码"
        )

        #expect(!classifier.isStrongVerificationField(snapshot))
    }

    @Test func rejectsWideTextFieldWithSearchKeyword() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            placeholder: "搜索内容",
            value: "",
            width: 240,
            siblingTextInputCount: 6
        )

        #expect(!classifier.isStrongVerificationField(snapshot))
    }

    @Test func acceptsMediumEmptyTextFieldWithoutKeywordLikeQuarkOtp() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            value: "",
            width: 326,
            siblingTextInputCount: 1
        )

        #expect(classifier.isStrongVerificationField(snapshot))
    }

    @Test func acceptsEmptyShortTextField() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            value: "",
            width: 120
        )

        #expect(classifier.isStrongVerificationField(snapshot))
    }

    @Test func refocusAcceptsVerificationContextSegmentedOtpAndMediumEmptyFields() {
        let classifier = FocusedElementClassifier()
        let verificationField = FocusedElementSnapshot(
            role: "AXTextField",
            placeholder: "请输入验证码",
            value: "",
            width: 280
        )
        let segmentedOtp = FocusedElementSnapshot(
            role: "AXTextField",
            value: "",
            width: 42,
            siblingTextInputCount: 6
        )
        let genericEmptyField = FocusedElementSnapshot(
            role: "AXTextField",
            value: "",
            width: 120
        )
        let mediumEmptyField = FocusedElementSnapshot(
            role: "AXTextField",
            value: "",
            width: 326
        )
        let phoneField = FocusedElementSnapshot(
            role: "AXTextField",
            placeholder: "请输入手机号",
            value: "",
            width: 280
        )
        let searchField = FocusedElementSnapshot(
            role: "AXSearchField",
            placeholder: "搜索",
            value: "",
            width: 420
        )

        #expect(classifier.isSafeVerificationFieldForRefocus(verificationField))
        #expect(classifier.isSafeVerificationFieldForRefocus(segmentedOtp))
        #expect(classifier.isSafeVerificationFieldForRefocus(genericEmptyField))
        #expect(classifier.isSafeVerificationFieldForRefocus(mediumEmptyField))
        #expect(!classifier.isSafeVerificationFieldForRefocus(phoneField))
        #expect(!classifier.isSafeVerificationFieldForRefocus(searchField))
    }

    @Test func rejectsNormalLongSearchField() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXSearchField",
            placeholder: "搜索",
            value: "",
            width: 420
        )

        #expect(!classifier.isStrongVerificationField(snapshot))
    }

    @Test func rejectsNonTextRole() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXButton",
            title: "验证码",
            value: ""
        )

        #expect(!classifier.isStrongVerificationField(snapshot))
    }

    @Test func acceptsPhoneFieldByPlaceholder() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            placeholder: "请输入手机号",
            value: "",
            width: 280,
            context: "短信验证码登录"
        )

        #expect(classifier.isLikelyPhoneField(snapshot))
    }

    @Test func rejectsSearchFieldAsPhoneField() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXSearchField",
            placeholder: "搜索手机号相关内容",
            value: "",
            width: 620,
            context: "地址栏"
        )

        #expect(!classifier.isLikelyPhoneField(snapshot))
    }

    @Test func acceptsGenericAccountTextFieldForShortcutFlow() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            placeholder: "手机号/邮箱",
            value: "",
            width: 320,
            context: "验证码登录"
        )

        #expect(classifier.isAcceptableAccountField(snapshot))
    }

    @Test func rejectsAddressBarAsAccountTextField() {
        let classifier = FocusedElementClassifier()
        let snapshot = FocusedElementSnapshot(
            role: "AXTextField",
            title: "Address and search bar",
            value: "",
            width: 720
        )

        #expect(!classifier.isAcceptableAccountField(snapshot))
    }
}
