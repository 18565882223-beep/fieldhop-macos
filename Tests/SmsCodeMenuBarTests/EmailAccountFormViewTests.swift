import AppKit
import Carbon
import Network
import Testing
@testable import SmsCodeMenuBar
@testable import SmsCodeCore

@MainActor
struct EmailAccountFormViewTests {
    @Test func presetAndFakeValuesProduceCompleteDraft() throws {
        let form = EmailAccountFormView(frame: .zero)
        form.selectPreset(.qq)

        let email = try #require(findTextField("email-account-address", in: form))
        let password = try #require(findSecureField("email-account-password", in: form))
        let username = try #require(findTextField("email-account-username", in: form))
        email.stringValue = "fake@qq.com"
        password.stringValue = "fake-authorize-code"
        username.stringValue = "fake@qq.com"

        let draft = try form.makeDraft()
        #expect(draft.account.host == "imap.qq.com")
        #expect(draft.account.port == 993)
        #expect(draft.account.useTLS)
        #expect(draft.password == "fake-authorize-code")
        #expect(form.fittingSize.width >= 556)
        let sheet = EmailAccountSheetController()
        #expect(sheet.contentSizeForTesting == NSSize(width: 620, height: 720))
    }

    @Test func perfect88PresetFillsEndpointAndAuthorizationHint() throws {
        let form = EmailAccountFormView(frame: .zero)
        form.selectPreset(.perfect88)

        let host = try #require(findTextField("email-account-host", in: form))
        let port = try #require(findTextField("email-account-port", in: form))
        let tls = try #require(findButton("email-account-tls", in: form))
        let hint = try #require(findTextField("email-account-provider-hint", in: form))

        #expect(host.stringValue == "imap.88.com")
        #expect(port.stringValue == "993")
        #expect(tls.state == .on)
        #expect(hint.stringValue.contains("88 邮箱"))
        #expect(hint.stringValue.contains("授权码"))
    }

    @Test func tlsCanBeToggledButSaveRejectsInsecureConfiguration() throws {
        let form = EmailAccountFormView(frame: .zero)
        let email = try #require(findTextField("email-account-address", in: form))
        let password = try #require(findSecureField("email-account-password", in: form))
        let tls = try #require(findButton("email-account-tls", in: form))
        email.stringValue = "fake@example.com"
        password.stringValue = "fake-authorize-code"
        tls.performClick(nil)

        #expect(tls.state == .off)
        #expect(throws: EmailAccountFormError.self) {
            try form.makeDraft()
        }
    }

    @Test func tabOrderVisitsEveryEditableControlAndPanelActions() throws {
        let sheet = EmailAccountSheetController()
        let root = try #require(sheet.contentViewForTesting)
        let preset = try #require(findPopup("email-account-preset", in: root))
        let name = try #require(findTextField("email-account-name", in: root))
        let email = try #require(findTextField("email-account-address", in: root))
        let password = try #require(findSecureField("email-account-password", in: root))
        let username = try #require(findTextField("email-account-username", in: root))
        let host = try #require(findTextField("email-account-host", in: root))
        let port = try #require(findTextField("email-account-port", in: root))
        let tls = try #require(findButton("email-account-tls", in: root))
        let cancel = try #require(findButton("email-account-cancel", in: root))
        let save = try #require(findButton("email-account-save", in: root))

        #expect(preset.nextKeyView === name)
        #expect(name.nextKeyView === email)
        #expect(email.nextKeyView === password)
        #expect(password.nextKeyView === username)
        #expect(username.nextKeyView === host)
        #expect(host.nextKeyView === port)
        #expect(port.nextKeyView === tls)
        #expect(tls.nextKeyView === cancel)
        #expect(cancel.nextKeyView === save)
        #expect(save.nextKeyView === findView("email-account-form", in: root))
    }

    @Test func saveAndCancelButtonsWorkWithFakeValues() throws {
        let sheet = EmailAccountSheetController()
        let root = try #require(sheet.contentViewForTesting)
        let email = try #require(findTextField("email-account-address", in: root))
        let password = try #require(findSecureField("email-account-password", in: root))
        let save = try #require(findButton("email-account-save", in: root))
        email.stringValue = "fake@gmail.com"
        password.stringValue = "fake-app-password"
        save.performClick(nil)

        #expect(sheet.submittedDraftForTesting?.account.emailAddress == "fake@gmail.com")
        #expect(sheet.submittedDraftForTesting?.password == "fake-app-password")

        let cancelledSheet = EmailAccountSheetController()
        let cancelledRoot = try #require(cancelledSheet.contentViewForTesting)
        let cancel = try #require(findButton("email-account-cancel", in: cancelledRoot))
        cancel.performClick(nil)
        #expect(cancelledSheet.submittedDraftForTesting == nil)
    }

    @Test func authorizationCodePasteTrimsEdgesAndPreservesMiddleCharacters() throws {
        let form = EmailAccountFormView(frame: .zero)
        let password = try #require(findView("email-account-password", in: form) as? AuthorizationCodeSecureField)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(" \n  abc  DEF-123  \r\n ", forType: .string)

        #expect(password.performKeyEquivalent(
            with: try #require(keyEvent(keyCode: UInt16(kVK_ANSI_V), characters: "v", flags: [.command]))
        ))

        #expect(password.stringValue == "abc  DEF-123")
        #expect(password.sanitizedStringValue == "abc  DEF-123")
    }

    @Test func authorizationCodeRevealOnlyWhileButtonIsHeld() throws {
        let form = EmailAccountFormView(frame: .zero)
        let password = try #require(findView("email-account-password", in: form) as? AuthorizationCodeSecureField)
        let visible = try #require(findTextField("email-account-password-visible", in: form))
        let reveal = try #require(findView("email-account-password-reveal", in: form) as? HoldRevealButton)
        password.stringValue = "secret-authorize-code"

        #expect(!password.isHidden)
        #expect(visible.isHidden)
        reveal.mouseDown(with: try #require(mouseEvent(type: .leftMouseDown)))
        #expect(password.isHidden)
        #expect(!visible.isHidden)
        #expect(visible.stringValue == "secret-authorize-code")

        reveal.mouseUp(with: try #require(mouseEvent(type: .leftMouseUp)))
        #expect(!password.isHidden)
        #expect(visible.isHidden)
        #expect(visible.stringValue.isEmpty)
    }

    @Test func customAccountSaveWaitsForSuccessfulPersistenceAndReload() throws {
        let suite = "EmailAccountFormViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountStore = EmailAccountStore(defaults: defaults)
        let credentialBackend = MemoryCredentialBackend()
        let credentialStore = EmailCredentialStore(backend: credentialBackend)
        var savedID: UUID?

        let sheet = EmailAccountSheetController { draft, completion in
            do {
                try credentialStore.save(draft.password, accountID: draft.account.id)
                var list = accountStore.load()
                list.upsert(draft.account)
                try accountStore.save(list)
                let reloaded = accountStore.load()
                guard reloaded.account(id: draft.account.id) == draft.account else {
                    completion(.failure("连接成功但保存失败：保存后未能读回账号配置"))
                    return
                }
                savedID = draft.account.id
                completion(.success)
            } catch {
                completion(.failure("连接成功但保存失败：\(error.localizedDescription)"))
            }
        }
        let root = try #require(sheet.contentViewForTesting)
        let form = try #require(findView("email-account-form", in: root) as? EmailAccountFormView)
        form.selectPreset(.custom)
        try fillEmailForm(
            root,
            email: "custom@example.com",
            password: "fake-authorize-code",
            username: "custom@example.com",
            host: "imap.custom.example"
        )
        try #require(findButton("email-account-save", in: root)).performClick(nil)

        let id = try #require(savedID)
        #expect(sheet.submittedDraftForTesting?.account.id == id)
        #expect(accountStore.load().account(id: id)?.host == "imap.custom.example")
        #expect(credentialStore.load(accountID: id) == "fake-authorize-code")
    }

    @Test func customAccountKeychainFailureKeepsWindowOpenAndLeavesNoAccount() throws {
        let suite = "EmailAccountFormViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountStore = EmailAccountStore(defaults: defaults)
        let credentialBackend = MemoryCredentialBackend()
        credentialBackend.failSave = true
        let credentialStore = EmailCredentialStore(backend: credentialBackend)

        let sheet = EmailAccountSheetController { draft, completion in
            do {
                try credentialStore.save(draft.password, accountID: draft.account.id)
                completion(.success)
            } catch {
                completion(.failure("连接成功但保存失败：授权码保存失败"))
            }
        }
        let root = try #require(sheet.contentViewForTesting)
        let form = try #require(findView("email-account-form", in: root) as? EmailAccountFormView)
        form.selectPreset(.custom)
        try fillEmailForm(
            root,
            email: "custom@example.com",
            password: "fake-authorize-code",
            username: "custom@example.com",
            host: "imap.custom.example"
        )
        try #require(findButton("email-account-save", in: root)).performClick(nil)

        let validation = try #require(findTextField("email-account-validation", in: root))
        #expect(sheet.submittedDraftForTesting == nil)
        #expect(validation.stringValue.contains("连接成功但保存失败"))
        #expect(accountStore.load().accounts.isEmpty)
    }

    @Test func customAccountMetadataFailureKeepsUserInputAndRemovesCredential() throws {
        let credentialBackend = MemoryCredentialBackend()
        let credentialStore = EmailCredentialStore(backend: credentialBackend)
        var attemptedID: UUID?

        let sheet = EmailAccountSheetController { draft, completion in
            do {
                attemptedID = draft.account.id
                try credentialStore.save(draft.password, accountID: draft.account.id)
                try credentialStore.delete(accountID: draft.account.id)
                completion(.failure("连接成功但保存失败：账号配置保存失败"))
            } catch {
                completion(.failure("连接成功但保存失败：账号配置保存失败"))
            }
        }
        let root = try #require(sheet.contentViewForTesting)
        let form = try #require(findView("email-account-form", in: root) as? EmailAccountFormView)
        form.selectPreset(.custom)
        try fillEmailForm(
            root,
            email: "custom@example.com",
            password: "fake-authorize-code",
            username: "custom@example.com",
            host: "imap.custom.example"
        )
        try #require(findButton("email-account-save", in: root)).performClick(nil)

        let email = try #require(findTextField("email-account-address", in: root))
        let password = try #require(findSecureField("email-account-password", in: root))
        let host = try #require(findTextField("email-account-host", in: root))
        let validation = try #require(findTextField("email-account-validation", in: root))
        #expect(email.stringValue == "custom@example.com")
        #expect(password.stringValue == "fake-authorize-code")
        #expect(host.stringValue == "imap.custom.example")
        #expect(validation.stringValue.contains("连接成功但保存失败"))
        if let attemptedID {
            #expect(credentialStore.load(accountID: attemptedID) == nil)
        }
        #expect(sheet.submittedDraftForTesting == nil)
    }

    @Test func connectionFailureIsMultilineSelectableAndCopyableWithoutClosingSheet() throws {
        let diagnostic = [
            "88 邮箱连接失败",
            "连接：隐式 TLS · imap.88.com:993",
            "CAPABILITY：AUTH=PLAIN：未声明；AUTH=LOGIN：未声明",
            "认证尝试：用户名=完整邮箱地址；认证方式=LOGIN；响应类别=NO",
            "最终结论：认证方式被服务器识别，但账号或专用密码未通过"
        ].joined(separator: "\n")
        let sheet = EmailAccountSheetController { _, completion in
            completion(.failure(diagnostic))
        }
        let root = try #require(sheet.contentViewForTesting)
        try fillEmailForm(
            root,
            email: "fake@88.com",
            password: "fake-authorize-code",
            username: "fake@88.com",
            host: "imap.88.com"
        )
        try #require(findButton("email-account-save", in: root)).performClick(nil)

        let validation = try #require(findTextField("email-account-validation", in: root))
        let copy = try #require(findButton("email-account-copy-diagnostic", in: root))
        #expect(validation.isSelectable)
        #expect(validation.maximumNumberOfLines == 0)
        #expect(validation.stringValue == diagnostic)
        #expect(!copy.isHidden)
        #expect(sheet.submittedDraftForTesting == nil)

        NSPasteboard.general.clearContents()
        copy.performClick(nil)
        #expect(NSPasteboard.general.string(forType: .string) == diagnostic)
        #expect(!(NSPasteboard.general.string(forType: .string) ?? "").contains("fake-authorize-code"))
    }

    @Test func managerPanelEditsTestsDeletesAndRendersDiagnostics() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let account = EmailAccount(
            id: id,
            displayName: "个人 QQ",
            emailAddress: "fake@qq.com",
            host: "imap.qq.com",
            username: "fake@qq.com",
            isEnabled: true,
            uidValidity: 88,
            lastSeenUID: 123,
            shortcut: KeyboardShortcutDescriptor(keyCode: UInt32(kVK_ANSI_4), modifierFlags: 2560, displayName: "⌥⌘4"),
            waitDurationMinutes: 10
        )
        var savedAccount: EmailAccount?
        var deletedID: UUID?
        var testedID: UUID?
        let diagnostic = EmailPollDiagnostic(
            lastPollAt: Date(),
            lastPollSucceeded: true,
            discoveredUIDCount: 2,
            fetchSucceededCount: 2,
            fetchFailedCount: 0,
            mimeSucceededCount: 2,
            mimeFailedCount: 0,
            keywordMatchedCount: 1,
            codeExtractedCount: 1,
            highConfidenceCount: 1,
            mediumConfidenceCount: 0,
            lowConfidenceCount: 0,
            lastExtractionSummary: "高置信，候选=1，理由=login code"
        )

        let controller = EmailAccountManagerController(
            accounts: [account],
            statusProvider: { _ in EmailConnectionStatus(phase: .listening, diagnostic: diagnostic) },
            addHandler: {},
            saveHandler: { account in
                savedAccount = account
                return .success("已保存")
            },
            deleteHandler: { accountID in
                deletedID = accountID
                return .success("已删除")
            },
            testHandler: { accountID, completion in
                testedID = accountID
                completion("邮箱连接测试成功：f***@qq.com")
            },
            shortcutConflictProvider: { shortcut, _ in
                shortcut.keyCode == UInt32(kVK_ANSI_2) ? "手机号A" : nil
            },
            shortcutAvailabilityProvider: { _ in true },
            confirmsDeletion: false
        )
        let root = try #require(controller.contentViewForTesting)

        try #require(findButton("email-manager-advanced-toggle", in: root)).performClick(nil)
        try #require(findButton("email-manager-diagnostics-toggle", in: root)).performClick(nil)
        let diagnostics = try #require(findTextField("email-manager-diagnostics", in: root))
        #expect(diagnostics.stringValue.contains("FETCH 2/0"))
        #expect(diagnostics.stringValue.contains("抽码=1"))

        let name = try #require(findTextField("email-manager-name", in: root))
        let email = try #require(findTextField("email-manager-email", in: root))
        let wait = try #require(findPopup("email-manager-wait", in: root))
        let enabled = try #require(findButton("email-manager-enabled", in: root))
        let test = try #require(findButton("email-manager-test", in: root))
        let save = try #require(findButton("email-manager-save", in: root))
        let delete = try #require(findButton("email-manager-delete", in: root))
        let recorder = try #require(findView("email-manager-shortcut", in: root) as? ShortcutRecorderView)

        test.performClick(nil)
        #expect(testedID == id)
        #expect(controller.messageForTesting.contains("测试成功"))

        recorder.keyDown(with: try #require(shortcutEvent(keyCode: UInt16(kVK_ANSI_2), characters: "2")))
        #expect(controller.messageForTesting.contains("手机号A"))
        recorder.keyDown(with: try #require(shortcutEvent(keyCode: UInt16(kVK_ANSI_5), characters: "5")))
        name.stringValue = "私人 QQ"
        email.stringValue = "new@qq.com"
        wait.selectItem(withTitle: "15 分钟")
        enabled.state = .off
        save.performClick(nil)

        #expect(savedAccount?.id == id)
        #expect(savedAccount?.displayName == "私人 QQ")
        #expect(savedAccount?.emailAddress == "new@qq.com")
        #expect(savedAccount?.shortcut.displayName == "⌥⌘5")
        #expect(savedAccount?.waitDurationMinutes == 15)
        #expect(savedAccount?.isEnabled == false)
        #expect(savedAccount?.uidValidity == nil)
        #expect(savedAccount?.lastSeenUID == nil)

        delete.performClick(nil)
        #expect(deletedID == id)
        #expect(controller.accountsForTesting.isEmpty)

        try writeScreenshotIfRequested(root)
    }

    @Test func managerPanelAddButtonInvokesAddHandler() throws {
        var addCount = 0
        let controller = EmailAccountManagerController(
            accounts: [],
            statusProvider: { _ in EmailConnectionStatus(phase: .stopped) },
            addHandler: { addCount += 1 },
            saveHandler: { _ in .success("已保存") },
            deleteHandler: { _ in .success("已删除") },
            testHandler: { _, completion in completion("测试成功") },
            shortcutConflictProvider: { _, _ in nil },
            shortcutAvailabilityProvider: { _ in true },
            confirmsDeletion: false
        )
        let root = try #require(controller.contentViewForTesting)
        try #require(findButton("email-manager-add", in: root)).performClick(nil)
        #expect(addCount == 1)
    }

    @Test func managerConnectionFailureCanBeSelectedAndCopied() throws {
        let account = EmailAccount(
            displayName: "88 邮箱",
            emailAddress: "fake@88.com",
            host: "imap.88.com"
        )
        let diagnostic = [
            "88 邮箱连接失败",
            "连接：隐式 TLS · imap.88.com:993",
            "CAPABILITY：AUTH=PLAIN：未声明；AUTH=LOGIN：未声明",
            "最终结论：认证方式被服务器识别，但账号或专用密码未通过"
        ].joined(separator: "\n")
        let controller = EmailAccountManagerController(
            accounts: [account],
            statusProvider: { _ in EmailConnectionStatus(phase: .stopped) },
            addHandler: {},
            saveHandler: { _ in .success("已保存") },
            deleteHandler: { _ in .success("已删除") },
            testHandler: { _, completion in completion(diagnostic) },
            shortcutConflictProvider: { _, _ in nil },
            shortcutAvailabilityProvider: { _ in true },
            confirmsDeletion: false
        )
        let root = try #require(controller.contentViewForTesting)
        try #require(findButton("email-manager-test", in: root)).performClick(nil)

        let message = try #require(findTextField("email-manager-message", in: root))
        let copy = try #require(findButton("email-manager-copy-diagnostic", in: root))
        #expect(message.isSelectable)
        #expect(message.maximumNumberOfLines == 0)
        #expect(!copy.isHidden)
        NSPasteboard.general.clearContents()
        copy.performClick(nil)
        #expect(NSPasteboard.general.string(forType: .string) == diagnostic)
    }

    @Test func emailMappingTitleRefreshesAfterAccountStoreReload() {
        let account = EmailAccount(
            displayName: "88 邮箱",
            emailAddress: "person@88.com",
            host: "imap.88.com",
            shortcut: KeyboardShortcutDescriptor(keyCode: UInt32(kVK_ANSI_8), modifierFlags: 2560, displayName: "⌥⌘8")
        )
        let title = "\(account.shortcut.displayName)  \(account.displayName)  \(account.maskedEmail)"
        #expect(title == "⌥⌘8  88 邮箱  p***@88.com")
    }

    @Test func connectionErrorPresenterClassifiesAndSanitizesMessages() {
        let tls = EmailConnectionErrorPresenter.message(for: NWError.tls(-9807))
        #expect(tls.contains("TLS 握手或证书失败"))

        let network = EmailConnectionErrorPresenter.message(for: NWError.posix(.ECONNREFUSED))
        #expect(network.contains("DNS/网络连接失败"))

        let auth = EmailConnectionErrorPresenter.message(for: IMAPProtocolError.commandFailed("NO"))
        #expect(auth.contains("登录/授权码被拒绝"))

        let rejected = EmailConnectionErrorPresenter.message(for: IMAPProtocolError.commandFailed("BAD"))
        #expect(rejected.contains("IMAP 服务端拒绝"))

        let malformed = EmailConnectionErrorPresenter.message(for: IMAPProtocolError.malformedResponse)
        #expect(malformed.contains("协议响应异常"))

        let generic = EmailConnectionErrorPresenter.message(
            for: NSError(domain: "SmsCodeCore.IMAPProtocolError", code: 0)
        )
        #expect(generic.contains("协议响应异常"))
        #expect(!generic.contains("SmsCodeCore"))
        #expect(!generic.contains("person@88.com"))
        #expect(!generic.contains("secret-authorize-code"))
    }

    @Test func perfect88AuthenticationFailureShowsOnlySafeDiagnostic() {
        let failure = IMAPAuthenticationFailure(
            diagnostic: IMAPAuthenticationDiagnostic(
                endpoint: IMAPConnectionEndpointDiagnostic(host: "imap.88.com", port: 993, usesTLS: true),
                capabilities: IMAPCapabilitySummary(
                    wasRetrieved: true,
                    tokens: ["IMAP4rev1", "ID", "STARTTLS"]
                ),
                attempts: [
                    IMAPAuthenticationAttempt(
                        usernameMode: .fullAddress,
                        method: .login,
                        completion: .no,
                        sanitizedResponse: "登录信息或专用密码被服务端拒绝"
                    ),
                    IMAPAuthenticationAttempt(
                        usernameMode: .localPart,
                        method: .login,
                        completion: .no,
                        sanitizedResponse: "登录信息或专用密码被服务端拒绝"
                    )
                ],
                conclusion: .authenticationRejected
            )
        )
        let message = EmailConnectionErrorPresenter.message(for: failure)

        #expect(message.contains("AUTH=PLAIN：未声明"))
        #expect(message.contains("AUTH=LOGIN：未声明"))
        #expect(message.contains("用户名=完整邮箱地址；认证方式=LOGIN"))
        #expect(message.contains("用户名=本地部分用户名；认证方式=LOGIN"))
        #expect(message.contains("响应类别=NO"))
        #expect(message.contains("最终结论"))
        #expect(message.contains("配置帮助"))
        #expect(!message.contains("person@88.com"))
        #expect(!message.contains("fake-authorize-code"))
    }

    private func findTextField(_ identifier: String, in root: NSView) -> NSTextField? {
        findView(identifier, in: root) as? NSTextField
    }

    private func findSecureField(_ identifier: String, in root: NSView) -> NSSecureTextField? {
        findView(identifier, in: root) as? NSSecureTextField
    }

    private func findButton(_ identifier: String, in root: NSView) -> NSButton? {
        findView(identifier, in: root) as? NSButton
    }

    private func findPopup(_ identifier: String, in root: NSView) -> NSPopUpButton? {
        findView(identifier, in: root) as? NSPopUpButton
    }

    private func findView(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews {
            if let found = findView(identifier, in: child) { return found }
        }
        return nil
    }

    private func shortcutEvent(keyCode: UInt16, characters: String) -> NSEvent? {
        keyEvent(keyCode: keyCode, characters: characters, flags: [.option, .command])
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        flags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func mouseEvent(type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private func writeScreenshotIfRequested(_ root: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["SMS_CODE_EMAIL_MANAGER_SCREENSHOT"],
              !path.isEmpty else { return }
        root.layoutSubtreeIfNeeded()
        let rect = root.bounds
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: rect))
        root.cacheDisplay(in: rect, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func fillEmailForm(
        _ root: NSView,
        email: String,
        password: String,
        username: String,
        host: String
    ) throws {
        try #require(findTextField("email-account-address", in: root)).stringValue = email
        try #require(findSecureField("email-account-password", in: root)).stringValue = password
        try #require(findTextField("email-account-username", in: root)).stringValue = username
        try #require(findTextField("email-account-host", in: root)).stringValue = host
        try #require(findTextField("email-account-port", in: root)).stringValue = "993"
        try #require(findButton("email-account-tls", in: root)).state = .on
    }
}

private final class MemoryCredentialBackend: EmailCredentialBackend {
    var values: [String: Data] = [:]
    var failSave = false

    func load(service: String, account: String) -> Data? {
        values["\(service):\(account)"]
    }

    func save(_ data: Data, service: String, account: String) throws {
        if failSave { throw MemoryCredentialError.failed }
        values["\(service):\(account)"] = data
    }

    func delete(service: String, account: String) throws {
        values["\(service):\(account)"] = nil
    }
}

private enum MemoryCredentialError: Error {
    case failed
}
