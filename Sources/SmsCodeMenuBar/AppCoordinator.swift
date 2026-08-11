import AppKit
import Carbon
import Foundation
import SmsCodeCore

struct AllowlistEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
}

private enum EmailAccountPersistenceError: LocalizedError {
    case credentialSaveFailed(String)
    case metadataSaveFailed(String)
    case reloadVerificationFailed

    var errorDescription: String? {
        switch self {
        case let .credentialSaveFailed(message):
            return "连接成功但保存失败：授权码保存失败（\(EmailLogSanitizer.sanitizeError(message))）"
        case let .metadataSaveFailed(message):
            return "连接成功但保存失败：账号配置保存失败（\(EmailLogSanitizer.sanitizeError(message))）"
        case .reloadVerificationFailed:
            return "连接成功但保存失败：保存后未能读回账号配置"
        }
    }
}

@MainActor
final class AppCoordinator {
    private var stateObservers: [() -> Void] = []

    private let reader: MessagesDatabaseReader
    private let databaseURL: URL
    private let shouldEnableLaunchAtLoginByDefault: Bool
    private let selector = VerificationCodeSelector()
    private let accessibilityReader = AccessibilityReader()
    private let classifier = FocusedElementClassifier()
    private lazy var verificationFieldLocator = VerificationFieldLocator(
        accessibilityReader: accessibilityReader,
        classifier: classifier
    )
    private let loginButtonMatcher = LoginButtonMatcher()
    private let verificationRequestMatcher = VerificationRequestButtonMatcher()
    private let requiredAgreementMatcher = RequiredAgreementMatcher()
    private let automationSettingsStore = AutomationSettingsStore()
    private let automationSafetyPolicy = AutomationSafetyPolicy()
    private let emailFillGate = EmailFillGate()
    private let hotKeyMonitor = GlobalHotKeyMonitor()
    private let phoneNumberStore = PhoneNumberStore()
    private let phoneAccountStore = PhoneAccountStore()
    private let emailAccountStore: EmailAccountStore
    private let emailCredentialStore = EmailCredentialStore()
    private let chromeBridgeServer: ChromeBridgeServer
    private let typer = KeyboardTyper()
    private let clipboard = ClipboardManager()
    private lazy var notificationService = NotificationService()
    private let launchAtLogin = LaunchAtLoginManager()
    private var monitor: MessagesChangeMonitor?
    private var messagePollingTask: Task<Void, Never>?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastMessageProcessingDate = Date.distantPast
    private var handledKeys = Set<String>()
    private var codeHistory = VerificationCodeHistory(maxCount: 5)
    private var phoneAccounts: PhoneAccountList
    private var emailAccounts: EmailAccountList
    private var emailConnectionStatuses: [UUID: EmailConnectionStatus] = [:]
    private var emailWaitSession: EmailWaitSession?
    private var preparingEmailAccountID: UUID?
    private var shouldFillPreparedEmail = false
    private var emailWaitExpiryTask: Task<Void, Never>?
    private var emailAccountManagerController: EmailAccountManagerController?
    private var loginSession: LoginAutomationSession?
    private var verificationRefocusTask: Task<Void, Never>?
    private var emailFillResultTask: Task<Void, Never>?
    private lazy var emailOTPMonitor = EmailOTPMonitor(
        clientFactory: { account in
            NetworkIMAPMailboxClient(account: account)
        },
        credentialProvider: { [weak self] accountID in
            self?.emailCredentialStore.load(accountID: accountID)
        },
        onCandidate: { [weak self] candidate in
            self?.handleEmailVerificationCandidate(candidate)
        },
        onStatus: { [weak self] accountID, status in
            self?.handleEmailStatus(accountID: accountID, status: status)
        },
        onWatermark: { [weak self] accountID, uidValidity, lastSeenUID in
            self?.updateEmailWatermark(
                accountID: accountID,
                uidValidity: uidValidity,
                lastSeenUID: lastSeenUID
            )
        },
        onReady: { [weak self] accountID in
            self?.emailWaitWatermarkReady(accountID: accountID)
        }
    )

    private(set) var recentCode: String?
    private(set) var recentAction: String = "等待验证码"
    private(set) var lastDiagnosticFileURL: URL?
    private var automationSettings: AutomationSettings
    private var isManuallyPaused = false
    private var pauseUntil: Date?
    private let isEmailFormUITestMode: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let emailAccountStore = EmailAccountStore()
        self.emailAccountStore = emailAccountStore
        if let databasePath = environment["SMS_CODE_DB_PATH"], !databasePath.isEmpty {
            self.databaseURL = URL(fileURLWithPath: databasePath)
        } else {
            self.databaseURL = MessagesDatabaseReader.defaultDatabaseURL()
        }
        self.reader = MessagesDatabaseReader(databaseURL: databaseURL)
        self.shouldEnableLaunchAtLoginByDefault = environment["SMS_CODE_DISABLE_LAUNCH_AT_LOGIN"] != "1"
        self.isEmailFormUITestMode = environment["SMS_CODE_EMAIL_FORM_UI_TEST"] == "1"
        self.chromeBridgeServer = ChromeBridgeServer(
            isDebugEndpointEnabled: environment["SMS_CODE_CHROME_BRIDGE_DEBUG"] == "1"
        )
        self.automationSettings = automationSettingsStore.load()
        self.phoneAccounts = phoneAccountStore.load()
        self.emailAccounts = emailAccountStore.load()
    }

    var maskedRecentCode: String {
        recentCode.map(CodeMasker.masked) ?? "暂无"
    }

    var hasAccessibilityPermission: Bool {
        accessibilityReader.hasPermission()
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLogin.isEnabled
    }

    var isAutoClickLoginEnabled: Bool {
        automationSettings.autoClickMode != .off
    }

    var isAutoCheckRequiredAgreementEnabled: Bool {
        automationSettings.autoCheckRequiredAgreement
    }

    var autoCheckRequiredAgreementTitle: String {
        automationSettings.autoCheckRequiredAgreement ? "开启" : "关闭"
    }

    var autoClickModeTitle: String {
        switch automationSettings.autoClickMode {
        case .trustedOnly:
            return "安全模式（名单内自动点）"
        case .aggressive:
            return "激进模式（风险词仍拦截）"
        case .off:
            return "关闭"
        }
    }

    var allowlistSummary: String {
        let hosts = automationSettings.allowedHosts.sorted()
        return hosts.isEmpty ? "空" : hosts.prefix(5).joined(separator: ", ")
    }

    var allowlistEntries: [AllowlistEntry] {
        let hostEntries = automationSettings.allowedHosts.sorted().map { host in
            AllowlistEntry(
                id: "host:\(host)",
                title: host,
                subtitle: "网页"
            )
        }
        let appEntries = automationSettings.allowedBundleIdentifiers.sorted().map { bundleID in
            AllowlistEntry(
                id: "app:\(bundleID)",
                title: bundleID,
                subtitle: "App"
            )
        }
        return hostEntries + appEntries
    }

    var verificationCodeHistoryItems: [VerificationCodeHistoryItem] {
        codeHistory.items
    }

    var maskedDefaultPhoneNumber: String {
        phoneNumberStore.load().map(CodeMasker.masked) ?? "未设置"
    }

    var phoneAccountItems: [PhoneAccount] {
        phoneAccounts.accounts
    }

    var phoneAccountSummary: String {
        let count = phoneAccounts.accounts.count
        return count == 0 ? "未添加" : "\(count) 个账号"
    }

    var emailAccountItems: [EmailAccount] {
        emailAccounts.accounts
    }

    var emailAccountSummary: String {
        let count = emailAccounts.accounts.count
        return count == 0 ? "未添加" : "\(count) 个账号"
    }

    var isEmailMonitoringEnabled: Bool {
        emailWaitSession != nil
    }

    var emailWaitStatusTitle: String {
        if let accountID = preparingEmailAccountID,
           let account = emailAccounts.account(id: accountID) {
            return "准备中：\(account.maskedEmail)"
        }
        guard let session = activeEmailWaitSession(),
              let account = emailAccounts.account(id: session.accountID) else {
            return "未等待"
        }
        let seconds = max(1, Int(session.expiresAt.timeIntervalSinceNow.rounded(.up)))
        return "正在等待：\(account.maskedEmail)（\(seconds / 60):\(String(format: "%02d", seconds % 60))）"
    }

    func emailStatus(for accountID: UUID) -> EmailConnectionStatus {
        emailConnectionStatuses[accountID] ?? EmailConnectionStatus(phase: .stopped)
    }

    var isPaused: Bool {
        if isManuallyPaused {
            return true
        }
        guard let pauseUntil else { return false }
        return pauseUntil > Date()
    }

    var pauseStatusTitle: String {
        if isManuallyPaused {
            return "无限暂停"
        }

        guard let pauseUntil, pauseUntil > Date() else {
            return "运行中"
        }

        let seconds = max(1, Int(pauseUntil.timeIntervalSinceNow.rounded(.up)))
        if seconds >= 60 {
            return "暂停中，约 \(seconds / 60) 分钟"
        }
        return "暂停中，约 \(seconds) 秒"
    }

    func addStateObserver(_ observer: @escaping () -> Void) {
        stateObservers.append(observer)
    }

    @discardableResult
    private func registerHotKeys() -> [GlobalHotKeyRegistration] {
        var registrations = [
            GlobalHotKeyRegistration(shortcut: smartFallbackShortcut, action: .smartFallback)
        ]

        registrations.append(contentsOf: phoneAccounts.enabledAccounts.map { account in
            GlobalHotKeyRegistration(shortcut: account.shortcut, action: .phoneAccount(account.id))
        })
        registrations.append(contentsOf: emailAccounts.enabledAccounts.map { account in
            GlobalHotKeyRegistration(shortcut: account.shortcut, action: .emailAccount(account.id))
        })

        return hotKeyMonitor.start(registrations: registrations) { [weak self] action in
            Task { @MainActor in
                self?.handleHotKey(action)
            }
        }
    }

    private var smartFallbackShortcut: KeyboardShortcutDescriptor {
        KeyboardShortcutDescriptor(
            keyCode: UInt32(kVK_ANSI_V),
            modifierFlags: UInt32(optionKey | cmdKey),
            displayName: "⌥⌘V"
        )
    }

    private func handleHotKey(_ action: GlobalHotKeyAction) {
        guard !isPaused else {
            recentAction = "当前已暂停，快捷键未执行"
            notifyStateChanged()
            return
        }

        switch action {
        case .smartFallback:
            handleSmartFallbackHotKey()
        case let .phoneAccount(accountID):
            startLoginWithPhoneAccount(accountID: accountID)
        case let .emailAccount(accountID):
            startEmailWaiting(accountID: accountID)
        }
    }

    private func migrateDefaultPhoneNumberIfNeeded() {
        guard phoneAccounts.accounts.isEmpty,
              let phoneNumber = phoneNumberStore.load() else {
            return
        }

        let account = PhoneAccount(
            name: "默认手机号",
            shortcut: PhoneAccountStore.defaultShortcut(index: 1)
        )

        do {
            try phoneNumberStore.save(phoneNumber, accountID: account.id)
            phoneAccounts.upsert(account)
            phoneAccountStore.save(phoneAccounts)
        } catch {
            recentAction = "默认手机号迁移失败"
        }
    }

    func start() {
        migrateDefaultPhoneNumberIfNeeded()
        registerHotKeys()

        do {
            try chromeBridgeServer.start()
        } catch {
            recentAction = "Chrome 桥接启动失败，将使用 AX 前半链路"
        }

        if !accessibilityReader.hasPermission() {
            accessibilityReader.requestPermissionPrompt()
            recentAction = "请先授权辅助功能"
        }

        do {
            if shouldEnableLaunchAtLoginByDefault && !launchAtLogin.isEnabled {
                try launchAtLogin.setEnabled(true)
            }
        } catch {
            recentAction = "开机自启设置失败"
        }

        let messagesDirectory = databaseURL.deletingLastPathComponent()
        monitor = MessagesChangeMonitor(watchedURL: messagesDirectory) { [weak self] in
            Task { @MainActor in
                self?.appendProcessLog("短信库变更事件触发")
                self?.scheduleProcessing()
            }
        }
        monitor?.start()
        appendProcessLog("短信监听已启动 path=\(messagesDirectory.path)")
        startMessagePollingFallback()
        processLatestMessage()
        refreshEmailMonitoring()
    }

    func togglePause() {
        if isPaused {
            resumeListening()
        } else {
            pauseUntilManualResume()
        }
    }

    func pauseFor(minutes: Int) {
        isManuallyPaused = false
        pauseUntil = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        endLoginSession(reason: "用户暂停监听")
        refreshEmailMonitoring()
        recentAction = "已暂停 \(minutes) 分钟"
        notifyStateChanged()

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(1, minutes) * 60)) { [weak self] in
            guard let self, !self.isPaused else { return }
            self.refreshEmailMonitoring()
            self.recentAction = "暂停结束，已恢复监听"
            self.notifyStateChanged()
        }
    }

    func pauseUntilManualResume() {
        isManuallyPaused = true
        pauseUntil = nil
        endLoginSession(reason: "用户无限暂停")
        refreshEmailMonitoring()
        recentAction = "已无限暂停"
        notifyStateChanged()
    }

    func resumeListening() {
        isManuallyPaused = false
        pauseUntil = nil
        recentAction = "已恢复监听"
        refreshEmailMonitoring()
        notifyStateChanged()
    }

    func requestAccessibilityPermission() {
        accessibilityReader.requestPermissionPrompt()
        notifyStateChanged()
    }

    func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            recentAction = launchAtLogin.isEnabled ? "已开启开机自启" : "已关闭开机自启"
        } catch {
            recentAction = "开机自启设置失败"
        }
        notifyStateChanged()
    }

    func copyRecentCode() {
        guard let recentCode else { return }
        let copied = copyLatestCodeToClipboard(recentCode, context: "手动复制最近验证码")
        recentAction = copied ? "最近验证码已复制" : "剪贴板写入失败，请重试"
        notifyStateChanged()
    }

    private func startMessagePollingFallback() {
        messagePollingTask?.cancel()
        messagePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self, !self.isPaused else { return }
                    self.scheduleProcessing()
                }
            }
        }
    }

    private func scheduleProcessing() {
        guard debounceWorkItem == nil else { return }

        let minimumInterval: TimeInterval = 1.0
        let elapsed = Date().timeIntervalSince(lastMessageProcessingDate)
        let delay = max(0.35, minimumInterval - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.debounceWorkItem = nil
                self.lastMessageProcessingDate = Date()
                self.processLatestMessage()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func processLatestMessage() {
        guard !isPaused else { return }

        do {
            let messages = try reader.latestMessages(limit: 30)
            guard let detected = selector.latestCode(in: messages) else {
                return
            }

            handleDetectedCode(
                detected.code,
                source: detected.message.service ?? "短信",
                dedupeKey: "sms:\(detected.message.date.timeIntervalSinceReferenceDate):\(detected.code)",
                detectedAt: detected.message.date
            )
        } catch {
            recentAction = "读取短信失败，请检查完全磁盘访问"
            notifyStateChanged()
        }
    }

    private func tryAutoPaste(_ code: String) {
        let decision = decidePasteAction()

        switch decision {
        case .pasteNow:
            if copyAndPaste(code, actionAfterPaste: "已自动粘贴填入") {
                recentAction = "准备自动粘贴"
                notifyStateChanged()
                scheduleAutoClickLogin()
            }
        case .retryOnce:
            guard copyLatestCodeToClipboard(code, context: "等待焦点稳定前复制") else {
                recentAction = "剪贴板写入失败，未自动粘贴"
                notifyStateChanged()
                return
            }
            recentAction = "等待焦点稳定，0.5秒后重试"
            notifyStateChanged()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                let retry = decidePasteAction()
                switch retry {
                case .pasteNow:
                    guard self.ensureClipboardContains(code, context: "重试粘贴前校验") else {
                        self.recentAction = "剪贴板写入失败，未自动粘贴"
                        self.notifyStateChanged()
                        return
                    }
                    self.typer.paste()
                    self.recentAction = "重试后已自动粘贴"
                    self.notifyStateChanged()
                    self.scheduleAutoClickLogin()
                case .retryOnce, .fallback:
                    self.recentAction = "重试仍无合适焦点，已复制到剪贴板"
                    self.notificationService.showClipboardFallback()
                    self.notifyStateChanged()
                }
            }
        case .fallback:
            let copied = copyFallback(code)
            recentAction = copied ? "已复制，等待手动粘贴" : "剪贴板写入失败，请重试"
            notifyStateChanged()
        }
    }

    private func scheduleAutoClickLogin() {
        guard isAutoClickLoginEnabled else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)

            guard self.isAutoClickLoginEnabled else { return }
            guard !self.isCurrentAppFrontmost() else { return }

            let context = self.accessibilityReader.targetContext()
            let autoClickDecision = self.automationSafetyPolicy.decision(
                settings: self.automationSettings,
                context: context
            )
            guard autoClickDecision.isAllowed else {
                self.recentAction = "已填入，\(autoClickDecision.reason)"
                self.notifyStateChanged()
                return
            }

            var foundButton: AXUIElement? = nil

            for attempt in 0..<3 {
                if let button = self.accessibilityReader.findLoginButtonNearFocus(matcher: self.loginButtonMatcher) {
                    foundButton = button
                    break
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            guard let button = foundButton else {
                self.recentAction = "已粘贴，未找到登录按钮"
                self.notifyStateChanged()
                return
            }

            let pressed = self.accessibilityReader.pressButton(button)
            self.recentAction = pressed ? "已粘贴并自动点击登录" : "已粘贴，点击登录失败"
            self.notifyStateChanged()
        }
    }

    func toggleAutoClickLogin() {
        switch automationSettings.autoClickMode {
        case .trustedOnly:
            automationSettings.autoClickMode = .aggressive
        case .aggressive:
            automationSettings.autoClickMode = .off
        case .off:
            automationSettings.autoClickMode = .trustedOnly
        }
        automationSettingsStore.save(automationSettings)
        recentAction = "自动点击：\(autoClickModeTitle)"
        notifyStateChanged()
    }

    func toggleAutoCheckRequiredAgreement() {
        automationSettings.autoCheckRequiredAgreement.toggle()
        automationSettingsStore.save(automationSettings)
        recentAction = "发送前自动勾协议：\(autoCheckRequiredAgreementTitle)"
        notifyStateChanged()
    }

    func trustCurrentTargetForAutoClick() {
        let context = accessibilityReader.targetContext()
        var didChange = false

        if let host = automationSafetyPolicy.normalizedHost(from: context.urlString) {
            automationSettings.allowedHosts.insert(host)
            didChange = true
            recentAction = "已加入网页白名单：\(host)"
        } else if let bundleIdentifier = context.bundleIdentifier {
            automationSettings.allowedBundleIdentifiers.insert(bundleIdentifier)
            didChange = true
            recentAction = "已加入 App 白名单：\(context.applicationName ?? bundleIdentifier)"
        } else {
            recentAction = "未识别到可加入白名单的目标"
        }

        if didChange {
            automationSettingsStore.save(automationSettings)
        }
        notifyStateChanged()
    }

    func removeAllowlistEntry(id: String) {
        if id.hasPrefix("host:") {
            let host = String(id.dropFirst("host:".count))
            automationSettings.allowedHosts.remove(host)
            automationSettingsStore.save(automationSettings)
            recentAction = "已移除网页白名单：\(host)"
        } else if id.hasPrefix("app:") {
            let bundleID = String(id.dropFirst("app:".count))
            automationSettings.allowedBundleIdentifiers.remove(bundleID)
            automationSettingsStore.save(automationSettings)
            recentAction = "已移除 App 白名单：\(bundleID)"
        } else {
            recentAction = "白名单项无效"
        }
        notifyStateChanged()
    }

    func promptAndSaveDefaultPhoneNumber() {
        let alert = NSAlert()
        alert.messageText = "设置默认手机号"
        alert.informativeText = "手机号会保存到系统 Keychain，不写入配置文件。留空会清除默认手机号。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = phoneNumberStore.load() ?? ""
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try phoneNumberStore.save(input.stringValue)
            recentAction = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "已清除默认手机号"
                : "已保存默认手机号"
        } catch {
            recentAction = "默认手机号保存失败"
        }
        notifyStateChanged()
    }

    func promptAndAddPhoneAccount() {
        let alert = NSAlert()
        alert.messageText = "添加手机号账号"
        alert.informativeText = "手机号保存到 Keychain。快捷键默认按顺序分配为 ⌥⌘1、⌥⌘2..."
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.placeholderString = "名称，例如：主号"
        let phoneField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        phoneField.placeholderString = "手机号"
        let stack = NSStackView(views: [nameField, phoneField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let phone = phoneField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else {
            recentAction = "手机号不能为空"
            notifyStateChanged()
            return
        }

        let accountIndex = phoneAccounts.accounts.count + 1
        let account = PhoneAccount(
            name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "手机号 \(accountIndex)"
                : nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            shortcut: PhoneAccountStore.defaultShortcut(index: accountIndex)
        )

        do {
            try phoneNumberStore.save(phone, accountID: account.id)
            phoneAccounts.upsert(account)
            phoneAccountStore.save(phoneAccounts)
            let failedRegistrations = registerHotKeys()
            if failedRegistrations.contains(where: { $0.shortcut == account.shortcut }) {
                recentAction = "账号已添加，但 \(account.shortcut.displayName) 注册失败"
            } else {
                recentAction = "已添加账号：\(account.name)（\(account.shortcut.displayName)）"
            }
        } catch {
            recentAction = "添加手机号账号失败"
        }
        notifyStateChanged()
    }

    func removePhoneAccount(id: UUID) {
        guard let account = phoneAccounts.account(id: id) else { return }
        phoneAccounts.remove(id: id)
        phoneAccountStore.save(phoneAccounts)
        try? phoneNumberStore.delete(accountID: id)
        let failedRegistrations = registerHotKeys()
        recentAction = failedRegistrations.isEmpty
            ? "已删除账号：\(account.name)"
            : "账号已删除，但部分快捷键注册失败"
        notifyStateChanged()
    }

    func toggleEmailMonitoring() {
        emailAccountStore.isMonitoringEnabled.toggle()
        refreshEmailMonitoring()
        recentAction = emailAccountStore.isMonitoringEnabled ? "已开启邮箱监听" : "已关闭邮箱监听"
        notifyStateChanged()
    }

    func promptAndAddEmailAccount() {
        let sheet = EmailAccountSheetController { [weak self] draft, completion in
            guard let self else {
                completion(.failure("邮箱保存失败：窗口已关闭"))
                return
            }
            self.recentAction = "正在测试邮箱连接…"
            self.notifyStateChanged()
            Task { @MainActor in
                do {
                    let account = try await self.persistNewEmailAccount(draft)
                    self.refreshEmailMonitoring()
                    self.recentAction = "邮箱已保存：\(account.maskedEmail)"
                    self.appendProcessLog(
                        "邮箱账号已添加 account=\(account.id.uuidString) email=\(account.maskedEmail) uid=\(account.lastSeenUID ?? 0)"
                    )
                    self.notifyStateChanged()
                    completion(.success)
                } catch {
                    let message: String
                    if error is EmailAccountPersistenceError {
                        message = EmailLogSanitizer.sanitizeError(error.localizedDescription)
                    } else {
                        message = EmailConnectionErrorPresenter.message(for: error)
                    }
                    self.recentAction = message
                    self.notifyStateChanged()
                    completion(.failure(message))
                }
            }
        }
        _ = sheet.runModal()
    }

    private func persistNewEmailAccount(_ draft: EmailAccountDraft) async throws -> EmailAccount {
        let state = try await validateEmailConnection(
            account: draft.account,
            password: draft.password
        )
        var account = draft.account
        account.uidValidity = state.uidValidity
        account.lastSeenUID = state.maximumUID

        do {
            try emailCredentialStore.save(draft.password, accountID: account.id)
        } catch {
            throw EmailAccountPersistenceError.credentialSaveFailed(error.localizedDescription)
        }

        do {
            var updatedAccounts = emailAccounts
            updatedAccounts.upsert(account)
            try emailAccountStore.save(updatedAccounts)
            let reloadedAccounts = emailAccountStore.load()
            guard let reloadedAccount = reloadedAccounts.account(id: account.id),
                  reloadedAccount == account else {
                throw EmailAccountPersistenceError.reloadVerificationFailed
            }
            emailAccounts = reloadedAccounts
            emailAccountManagerController?.reload(accounts: emailAccounts.accounts, keepSelection: false)
            return reloadedAccount
        } catch {
            try? emailCredentialStore.delete(accountID: account.id)
            if let persistenceError = error as? EmailAccountPersistenceError {
                throw persistenceError
            }
            throw EmailAccountPersistenceError.metadataSaveFailed(error.localizedDescription)
        }
    }

    func showEmailAccountManager() {
        if emailAccountManagerController == nil {
            emailAccountManagerController = EmailAccountManagerController(
                accounts: emailAccounts.accounts,
                statusProvider: { [weak self] accountID in
                    self?.emailStatus(for: accountID) ?? EmailConnectionStatus(phase: .stopped)
                },
                addHandler: { [weak self] in
                    self?.promptAndAddEmailAccount()
                },
                saveHandler: { [weak self] account in
                    self?.saveEmailAccountFromManager(account) ?? .failure("邮箱管理器不可用")
                },
                deleteHandler: { [weak self] accountID in
                    self?.deleteEmailAccountFromManager(accountID) ?? .failure("邮箱管理器不可用")
                },
                testHandler: { [weak self] accountID, completion in
                    self?.testEmailConnectionForManager(id: accountID, completion: completion)
                },
                shortcutConflictProvider: { [weak self] shortcut, accountID in
                    self?.shortcutConflictName(for: shortcut, excluding: accountID)
                },
                shortcutAvailabilityProvider: { shortcut in
                    GlobalHotKeyMonitor.canRegister(shortcut)
                }
            )
        }
        emailAccountManagerController?.reload(accounts: emailAccounts.accounts, keepSelection: true)
        emailAccountManagerController?.show()
    }

    func testEmailConnection(id: UUID) {
        guard let account = emailAccounts.account(id: id),
              let password = emailCredentialStore.load(accountID: id) else {
            recentAction = "该邮箱未保存应用专用密码"
            notifyStateChanged()
            return
        }
        recentAction = "正在测试 \(account.maskedEmail)…"
        notifyStateChanged()
        Task { @MainActor in
            do {
                _ = try await validateEmailConnection(account: account, password: password)
                recentAction = "邮箱连接测试成功：\(account.maskedEmail)"
            } catch {
                recentAction = EmailConnectionErrorPresenter.message(for: error)
            }
            notifyStateChanged()
        }
    }

    func toggleEmailAccount(id: UUID) {
        guard var account = emailAccounts.account(id: id) else { return }
        account.isEnabled.toggle()
        var updated = emailAccounts
        updated.upsert(account)
        do {
            try emailAccountStore.save(updated)
            emailAccounts = updated
            refreshEmailMonitoring()
            recentAction = account.isEnabled
                ? "已启用邮箱：\(account.maskedEmail)"
                : "已停用邮箱：\(account.maskedEmail)"
        } catch {
            recentAction = "邮箱状态保存失败"
        }
        notifyStateChanged()
    }

    func removeEmailAccount(id: UUID) {
        guard let account = emailAccounts.account(id: id) else { return }
        var updated = emailAccounts
        updated.remove(id: id)
        do {
            try emailCredentialStore.delete(accountID: id)
            try emailAccountStore.save(updated)
            emailAccounts = updated
            refreshEmailMonitoring()
            emailConnectionStatuses[id] = nil
            recentAction = "已删除邮箱：\(account.maskedEmail)"
            appendProcessLog("邮箱账号已删除 account=\(id.uuidString)")
        } catch {
            recentAction = "删除邮箱失败"
        }
        notifyStateChanged()
    }

    private func saveEmailAccountFromManager(_ account: EmailAccount) -> EmailAccountManagerResult {
        guard emailAccounts.account(id: account.id) != nil else {
            return .failure("邮箱账号不存在")
        }
        if let conflictName = shortcutConflictName(for: account.shortcut, excluding: account.id) {
            return .failure("\(account.shortcut.displayName) 已被 \(conflictName) 使用")
        }
        var updated = emailAccounts
        updated.upsert(account)
        do {
            try emailAccountStore.save(updated)
            emailAccounts = updated
            let failedRegistrations = registerHotKeys()
            refreshEmailMonitoring()
            recentAction = "已保存邮箱：\(account.maskedEmail)"
            appendProcessLog("邮箱账号已保存 account=\(account.id.uuidString) email=\(account.maskedEmail)")
            notifyStateChanged()
            if failedRegistrations.contains(where: { $0.shortcut == account.shortcut }) {
                return .failure("\(account.shortcut.displayName) 注册失败，请换一个快捷键")
            }
            return .success("已保存：\(account.maskedEmail)")
        } catch {
            return .failure("邮箱账号保存失败")
        }
    }

    private func deleteEmailAccountFromManager(_ id: UUID) -> EmailAccountManagerResult {
        guard let account = emailAccounts.account(id: id) else {
            return .failure("邮箱账号不存在")
        }
        var updated = emailAccounts
        updated.remove(id: id)
        do {
            try emailCredentialStore.delete(accountID: id)
            try emailAccountStore.save(updated)
            emailAccounts = updated
            refreshEmailMonitoring()
            emailConnectionStatuses[id] = nil
            recentAction = "已删除邮箱：\(account.maskedEmail)"
            appendProcessLog("邮箱账号已删除 account=\(id.uuidString)")
            notifyStateChanged()
            return .success("已删除：\(account.maskedEmail)")
        } catch {
            return .failure("删除邮箱失败")
        }
    }

    private func testEmailConnectionForManager(
        id: UUID,
        completion: @escaping (String) -> Void
    ) {
        guard let account = emailAccounts.account(id: id),
              let password = emailCredentialStore.load(accountID: id) else {
            completion("该邮箱未保存应用专用密码")
            return
        }
        recentAction = "正在测试 \(account.maskedEmail)…"
        notifyStateChanged()
        Task { @MainActor in
            do {
                _ = try await validateEmailConnection(account: account, password: password)
                let message = "邮箱连接测试成功：\(account.maskedEmail)"
                recentAction = message
                completion(message)
            } catch {
                let message = EmailConnectionErrorPresenter.message(for: error)
                recentAction = message
                completion(message)
            }
            notifyStateChanged()
        }
    }

    private func validateEmailConnection(
        account: EmailAccount,
        password: String
    ) async throws -> IMAPMailboxState {
        if isEmailFormUITestMode {
            return IMAPMailboxState(uidValidity: 9_999, maximumUID: 0)
        }
        let client = NetworkIMAPMailboxClient(account: account)
        do {
            try await client.connect(
                username: account.username,
                password: password,
                requiresClientID: account.requiresIMAPID
            )
            let state = try await client.mailboxState()
            await client.disconnect()
            return state
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func refreshEmailMonitoring() {
        guard let session = activeEmailWaitSession(),
              !isPaused,
              let account = emailAccounts.account(id: session.accountID),
              account.isEnabled else {
            emailOTPMonitor.stopAll()
            return
        }
        emailOTPMonitor.startWaiting(account: account)
    }

    private func handleEmailStatus(accountID: UUID, status: EmailConnectionStatus) {
        emailConnectionStatuses[accountID] = status
        emailAccountManagerController?.refreshDiagnostics()
        appendProcessLog(
            "邮箱状态 account=\(accountID.uuidString) status=\(status.phase.rawValue) diagnostic=\(status.diagnosticText)"
        )
        notifyStateChanged()
    }

    private func updateEmailWatermark(accountID: UUID, uidValidity: UInt64, lastSeenUID: UInt64) {
        guard var account = emailAccounts.account(id: accountID) else { return }
        account.uidValidity = uidValidity
        account.lastSeenUID = lastSeenUID
        var updated = emailAccounts
        updated.upsert(account)
        do {
            try emailAccountStore.save(updated)
            emailAccounts = updated
            emailAccountManagerController?.refreshDiagnostics()
            appendProcessLog("邮箱水位线更新 account=\(accountID.uuidString) uid=\(lastSeenUID)")
        } catch {
            appendProcessLog("邮箱水位线保存失败 account=\(accountID.uuidString)")
        }
    }

    func handleEmailVerificationCandidate(_ candidate: VerificationCodeCandidate) {
        guard case let .email(accountID, uid) = candidate.source else { return }
        guard let session = activeEmailWaitSession(), session.accountID == accountID else {
            appendProcessLog("忽略非等待邮箱候选 account=\(accountID.uuidString) uid=\(uid)")
            return
        }
        guard candidate.date <= Date(), Date().timeIntervalSince(candidate.date) <= 180 else {
            appendProcessLog("邮箱验证码已过期 account=\(accountID.uuidString) uid=\(uid)")
            return
        }
        handleDetectedCode(
            candidate.code,
            source: "邮箱",
            dedupeKey: "email:\(accountID.uuidString):\(uid):\(candidate.code)",
            detectedAt: candidate.date
        )
        endEmailWaitSession(reason: "已处理邮箱验证码")
    }

    func startEmailWaiting(accountID: UUID) {
        guard !isPaused,
              let account = emailAccounts.account(id: accountID), account.isEnabled else {
            recentAction = "邮箱账号不存在、已停用或当前暂停"
            notifyStateChanged()
            return
        }
        guard accessibilityReader.hasPermission(), !isCurrentAppFrontmost(),
              let focused = accessibilityReader.focusedElement() else {
            recentAction = "请先点击邮箱框或验证码框"
            notifyStateChanged()
            return
        }
        let focusKind = emailFocusKind(focused)
        guard focusKind != .invalid else {
            recentAction = "请先点击邮箱框或验证码框"
            notifyStateChanged()
            return
        }

        endEmailWaitSession(reason: "切换邮箱等待")
        preparingEmailAccountID = accountID
        shouldFillPreparedEmail = focusKind == .email
        recentAction = "正在建立邮箱 UID 水位线…"
        appendProcessLog("邮箱等待准备 account=\(accountID.uuidString)")
        emailOTPMonitor.startWaiting(account: account)
        notifyStateChanged()
    }

    func cancelEmailWaiting() {
        endEmailWaitSession(reason: "用户取消")
        recentAction = "已取消邮箱等待"
        notifyStateChanged()
    }

    private enum EmailFocusKind { case email, verification, invalid }

    private func emailFocusKind(_ focused: FocusedElementSnapshot) -> EmailFocusKind {
        let text = [focused.title, focused.description, focused.placeholder, focused.context]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("password") || text.contains("密码") { return .invalid }
        if isVerificationEntryField(focused) { return .verification }
        if classifier.isLikelyPhoneField(focused) || text.contains("搜索") || text.contains("search") { return .invalid }
        if text.contains("email") || text.contains("邮箱") || text.contains("account") || text.contains("账号") {
            return .email
        }
        return .invalid
    }

    private func emailWaitWatermarkReady(accountID: UUID) {
        guard preparingEmailAccountID == accountID,
              let account = emailAccounts.account(id: accountID) else { return }
        preparingEmailAccountID = nil
        if shouldFillPreparedEmail {
            let context = accessibilityReader.targetContext()
            if shouldUseChromeBridge(context: context) {
                startChromeDOMEmailLogin(account: account, context: context) { [weak self] in
                    self?.beginEmailWaitSession(account: account)
                }
                shouldFillPreparedEmail = false
                return
            } else if !copyAndPaste(account.emailAddress, actionAfterPaste: "已填入邮箱：\(account.displayName)") {
                recentAction = "UID 水位线已建立，但邮箱写入失败"
                notifyStateChanged()
                return
            }
        }
        shouldFillPreparedEmail = false
        beginEmailWaitSession(account: account)
    }

    private func beginEmailWaitSession(account: EmailAccount) {
        emailWaitSession = EmailWaitSession(accountID: account.id, durationMinutes: account.waitDurationMinutes)
        scheduleEmailWaitExpiry()
        recentAction = "邮箱已准备，正在等待验证码"
        appendProcessLog("邮箱等待已开始 account=\(account.id.uuidString)")
        notifyStateChanged()
    }

    private func startChromeDOMEmailLogin(
        account: EmailAccount,
        context: AutomationTargetContext,
        completion: @escaping () -> Void
    ) {
        let commandID = chromeBridgeServer.enqueueEmailLogin(
            email: account.emailAddress,
            accountName: account.displayName,
            targetHost: automationSafetyPolicy.normalizedHost(from: context.urlString)
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let result = self.chromeBridgeServer.result(sessionID: commandID) else {
                self.recentAction = "UID 水位线已建立，请手动填入邮箱后发码"
                self.notifyStateChanged()
                return
            }
            if result.manualInterventionRequired == true {
                self.recentAction = "已准备等待，请手动完成人机验证后发码"
            } else if result.clickedRequest == true {
                self.recentAction = "已准备等待，已尝试发送邮箱验证码"
            } else {
                self.recentAction = "已准备等待，请手动完成发码"
            }
            completion()
            self.notifyStateChanged()
        }
    }

    private func activeEmailWaitSession(now: Date = Date()) -> EmailWaitSession? {
        guard let session = emailWaitSession else { return nil }
        guard !session.isExpired(now: now) else {
            endEmailWaitSession(reason: "等待超时")
            return nil
        }
        return session
    }

    private func scheduleEmailWaitExpiry() {
        emailWaitExpiryTask?.cancel()
        guard let session = emailWaitSession else { return }
        emailWaitExpiryTask = Task { @MainActor in
            let delay = max(1, UInt64(session.expiresAt.timeIntervalSinceNow * 1_000_000_000))
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, self.emailWaitSession == session else { return }
            self.endEmailWaitSession(reason: "等待超时")
            self.recentAction = "邮箱等待已超时"
            self.notifyStateChanged()
        }
    }

    private func endEmailWaitSession(reason: String) {
        emailWaitExpiryTask?.cancel()
        emailWaitExpiryTask = nil
        preparingEmailAccountID = nil
        shouldFillPreparedEmail = false
        if emailWaitSession != nil { appendProcessLog("邮箱等待结束：\(reason)") }
        emailWaitSession = nil
        emailOTPMonitor.stopAll()
    }

    private func handleDetectedCode(
        _ code: String,
        source: String,
        dedupeKey: String,
        detectedAt: Date
    ) {
        guard !handledKeys.contains(dedupeKey) else { return }
        handledKeys.insert(dedupeKey)
        recentCode = code
        codeHistory.record(code: code, date: detectedAt, source: source)
        appendProcessLog(
            "收到\(source)验证码 \(CodeMasker.masked(code)); "
                + "session=\(loginSession?.summary ?? "nil"); "
                + "currentAppFrontmost=\(isCurrentAppFrontmost())"
        )
        let clipboardReady = copyLatestCodeToClipboard(code, context: "收到\(source)验证码预置兜底")
            && ensureClipboardContains(code, context: "验证码剪贴板回读")
        appendProcessLog("兜底剪贴板预置结果=\(clipboardReady)")
        guard clipboardReady else {
            recentAction = "验证码已识别，但剪贴板写入失败"
            notifyStateChanged()
            return
        }

        if scheduleChromeBridgeCodeFill(code) { return }
        if scheduleFocusedChromeBridgeCodeFill(code) { return }
        if tryFillPendingVerificationField(code) {
            appendProcessLog("使用缓存验证码框回填")
            return
        }
        if scheduleSessionRefocusAndFill(code) { return }

        appendProcessLog("没有可用登录会话，进入焦点/剪贴板兜底")
        tryAutoPaste(code)
    }

    func promptAndSetShortcutForPhoneAccount(id: UUID) {
        guard var account = phoneAccounts.account(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "设置账号快捷键"
        alert.informativeText = "点击下方区域后，直接按新的组合键。建议包含 ⌘、⌥ 或 ⌃。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let recorder = ShortcutRecorderView(initialShortcut: account.shortcut)
        alert.accessoryView = recorder

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let shortcut = recorder.shortcut else {
            recentAction = "未录制到新快捷键"
            notifyStateChanged()
            return
        }

        if let conflictName = shortcutConflictName(for: shortcut, excluding: account.id) {
            recentAction = "\(shortcut.displayName) 已被 \(conflictName) 使用"
            notifyStateChanged()
            return
        }

        if shortcut != account.shortcut,
           !GlobalHotKeyMonitor.canRegister(shortcut) {
            recentAction = "\(shortcut.displayName) 已被系统或其他 App 占用"
            notifyStateChanged()
            return
        }

        account.shortcut = shortcut
        phoneAccounts.upsert(account)
        phoneAccountStore.save(phoneAccounts)
        let failedRegistrations = registerHotKeys()
        if failedRegistrations.contains(where: { $0.shortcut == shortcut }) {
            recentAction = "\(shortcut.displayName) 注册失败，请换一个快捷键"
        } else {
            recentAction = "已更新快捷键：\(account.name) \(shortcut.displayName)"
        }
        notifyStateChanged()
    }

    func startLoginWithPhoneAccount(accountID: UUID) {
        guard let account = phoneAccounts.account(id: accountID), account.isEnabled else {
            recentAction = "快捷键账号不存在或已停用"
            notifyStateChanged()
            return
        }

        guard let phoneNumber = phoneNumberStore.load(accountID: account.id) else {
            recentAction = "账号未保存手机号：\(account.name)"
            notifyStateChanged()
            return
        }

        startPhoneLoginFlow(
            phoneNumber: phoneNumber,
            accountName: account.name,
            shouldTrustFocusedAccountField: true
        )
    }

    func startLoginWithDefaultPhoneNumber() {
        guard let phoneNumber = phoneNumberStore.load() else {
            recentAction = "请先设置默认手机号"
            notifyStateChanged()
            return
        }

        startPhoneLoginFlow(
            phoneNumber: phoneNumber,
            accountName: "默认手机号",
            shouldTrustFocusedAccountField: false
        )
    }

    private func startPhoneLoginFlow(
        phoneNumber: String,
        accountName: String,
        shouldTrustFocusedAccountField: Bool
    ) {
        guard accessibilityReader.hasPermission() else {
            recentAction = "请先授权辅助功能"
            notifyStateChanged()
            return
        }

        guard !isCurrentAppFrontmost(),
              let focusedElement = accessibilityReader.focusedElement(),
              shouldAcceptAccountField(focusedElement, trustUserFocus: shouldTrustFocusedAccountField) else {
            recentAction = "请先点击手机号输入框"
            notifyStateChanged()
            return
        }
        let flowAnchor = accessibilityReader.currentAutomationAnchor()

        let context = accessibilityReader.targetContext()
        let fillDecision = automationSafetyPolicy.decision(
            settings: automationSettings,
            context: context,
            permission: .fillPhone
        )
        guard fillDecision.isAllowed else {
            recentAction = "\(fillDecision.reason)，已停止前半链路"
            notifyStateChanged()
            return
        }

        startLoginSession(anchor: flowAnchor, context: context)
        if shouldUseChromeBridge(context: context),
           let bridgeSessionID = startChromeDOMPhoneLogin(
               phoneNumber: phoneNumber,
               accountName: accountName,
               context: context
           ) {
            recentAction = "已交给 Chrome 扩展处理：\(accountName)"
            notifyStateChanged()

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let result = self.chromeBridgeServer.result(sessionID: bridgeSessionID) {
                    self.appendProcessLog(
                        "Chrome 前半链路结果 status=\(result.status); "
                            + "filledPhone=\(result.filledPhone == true); "
                            + "checkedAgreement=\(result.checkedAgreement == true); "
                            + "clickedNext=\(result.clickedNextStep == true); "
                            + "clickedRequest=\(result.clickedRequest == true); "
                            + "manual=\(result.manualInterventionRequired == true); "
                            + "message=\(result.message)"
                    )

                    if result.manualInterventionRequired == true {
                        self.recentAction = "需要手动完成页面验证，完成后等待短信"
                        self.appendProcessLog("Chrome 前半链路要求人工介入：\(result.message)")
                        self.notifyStateChanged()
                        return
                    }

                    if result.clickedRequest == true {
                        let field = self.accessibilityReader.findVerificationFieldNearAnchor(
                            flowAnchor,
                            classifier: self.classifier
                        ) ?? self.accessibilityReader.findVerificationFieldNearFocus(classifier: self.classifier)
                        self.loginSession?.cachedVerificationField = field
                        let focused = field.map { self.accessibilityReader.focusElement($0) } ?? (result.focusedVerification == true)
                        self.recentAction = focused
                            ? "Chrome 扩展已发码，等待短信"
                            : "Chrome 扩展已发码，请手动点验证码框"
                        self.notifyStateChanged()
                        return
                    }
                }

                self.recentAction = "Chrome 扩展未完成，回退 AX 前半链路"
                self.notifyStateChanged()
                self.runAXPhoneLoginFlowAfterSession(
                    phoneNumber: phoneNumber,
                    accountName: accountName,
                    flowAnchor: flowAnchor
                )
            }
            return
        }

        runAXPhoneLoginFlowAfterSession(
            phoneNumber: phoneNumber,
            accountName: accountName,
            flowAnchor: flowAnchor
        )
    }

    private func shouldUseChromeBridge(context: AutomationTargetContext) -> Bool {
        guard context.bundleIdentifier == "com.google.Chrome" else { return false }
        return true
    }

    private func startChromeDOMPhoneLogin(
        phoneNumber: String,
        accountName: String,
        context: AutomationTargetContext
    ) -> String? {
        let targetHost = automationSafetyPolicy.normalizedHost(from: context.urlString)
        return chromeBridgeServer.enqueuePhoneLogin(
            phoneNumber: phoneNumber,
            accountName: accountName,
            targetHost: targetHost
        )
    }

    private func runAXPhoneLoginFlowAfterSession(
        phoneNumber: String,
        accountName: String,
        flowAnchor: AXUIElement?
    ) {
        guard copyAndPaste(phoneNumber, actionAfterPaste: "已填入账号：\(accountName)") else {
            recentAction = "手机号写入剪贴板失败"
            notifyStateChanged()
            return
        }
        recentAction = "准备填入账号：\(accountName)"
        notifyStateChanged()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            let targetProcessID = self.loginSession?.targetProcessID
            let liveFlowAnchor = self.accessibilityReader.currentAutomationAnchor() ?? flowAnchor

            let requestContext = self.accessibilityReader.targetContext()
            let requestDecision = self.automationSafetyPolicy.decision(
                settings: self.automationSettings,
                context: requestContext,
                permission: .requestVerificationCode
            )
            guard requestDecision.isAllowed else {
                self.endLoginSession(reason: requestDecision.reason)
                self.recentAction = "已填手机号，\(requestDecision.reason)"
                self.notifyStateChanged()
                return
            }

            if self.automationSettings.autoCheckRequiredAgreement,
               (self.accessibilityReader.checkRequiredAgreement(
                   near: liveFlowAnchor,
                   matcher: self.requiredAgreementMatcher
               ) ?? self.accessibilityReader.checkRequiredAgreement(
                   inProcessID: targetProcessID,
                   matcher: self.requiredAgreementMatcher
               )) != nil {
                self.recentAction = "已自动勾选协议框"
                self.notifyStateChanged()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            try? await Task.sleep(nanoseconds: 600_000_000)
            let currentAnchor = self.accessibilityReader.currentAutomationAnchor() ?? liveFlowAnchor

            var clickedRequestControl = self.accessibilityReader.clickVerificationRequestControlNearAccountField(
                near: liveFlowAnchor,
                matcher: self.verificationRequestMatcher
            ) || self.accessibilityReader.clickVerificationRequestControlNearAccountField(
                near: currentAnchor,
                matcher: self.verificationRequestMatcher
            ) || self.accessibilityReader.clickVerificationRequestControl(
                inProcessID: targetProcessID,
                matcher: self.verificationRequestMatcher
            )

            if !clickedRequestControl {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let retryAnchor = self.accessibilityReader.currentAutomationAnchor() ?? liveFlowAnchor
                clickedRequestControl = self.accessibilityReader.clickVerificationRequestControlNearAccountField(
                    near: liveFlowAnchor,
                    matcher: self.verificationRequestMatcher
                ) || self.accessibilityReader.clickVerificationRequestControlNearAccountField(
                    near: retryAnchor,
                    matcher: self.verificationRequestMatcher
                ) || self.accessibilityReader.clickVerificationRequestControl(
                    inProcessID: targetProcessID,
                    matcher: self.verificationRequestMatcher
                )
            }

            if !clickedRequestControl {
                guard let button = self.findVerificationRequestButtonGlobally(anchor: liveFlowAnchor) else {
                    self.recentAction = "已填手机号，未找到发送验证码按钮，请手动点击"
                    self.notificationService.showClipboardFallback()
                    self.notifyStateChanged()
                    return
                }

                let pressed = self.accessibilityReader.clickWebAction(button)
                guard pressed else {
                    self.recentAction = "已填手机号，点击发送验证码失败，请手动点击"
                    self.notificationService.showClipboardFallback()
                    self.notifyStateChanged()
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 700_000_000)
            let field = self.accessibilityReader.findVerificationFieldNearAnchor(
                liveFlowAnchor,
                classifier: self.classifier
            ) ?? self.accessibilityReader.findVerificationFieldNearFocus(classifier: self.classifier)
            self.loginSession?.cachedVerificationField = field
            let focused = field.map { self.accessibilityReader.focusElement($0) } ?? false
            self.recentAction = focused
                ? "已尝试发送验证码，等待短信"
                : "已尝试发送验证码，请手动点验证码框"
            self.notifyStateChanged()
        }
    }

    private func findVerificationRequestButtonGlobally(anchor: AXUIElement?) -> AXUIElement? {
        if let anchor = anchor,
           let button = accessibilityReader.findVerificationRequestButton(
               near: anchor,
               matcher: verificationRequestMatcher
           ) {
            return button
        }

        if let button = accessibilityReader.findVerificationRequestButtonNearFocus(
            matcher: verificationRequestMatcher
        ) {
            return button
        }

        return accessibilityReader.findVerificationRequestButtonInWebArea(
            matcher: verificationRequestMatcher
        )
    }

    private func shouldAcceptAccountField(_ snapshot: FocusedElementSnapshot, trustUserFocus: Bool) -> Bool {
        if trustUserFocus {
            return classifier.isAcceptableAccountField(snapshot)
        }
        return classifier.isLikelyPhoneField(snapshot)
    }

    private func shortcutDigitString(from shortcut: KeyboardShortcutDescriptor) -> String? {
        let mapping: [UInt32: String] = [
            UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4",
            UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9"
        ]
        return mapping[shortcut.keyCode]
    }

    private func shortcutConflictName(
        for shortcut: KeyboardShortcutDescriptor,
        excluding accountID: UUID
    ) -> String? {
        if shortcut == smartFallbackShortcut {
            return "智能填入"
        }
        return phoneAccounts.accounts.first {
            $0.id != accountID && $0.shortcut == shortcut
        }?.name ?? emailAccounts.accounts.first(where: {
            $0.id != accountID && $0.shortcut == shortcut
        })?.displayName
    }

    private enum PasteDecision {
        case pasteNow
        case retryOnce
        case fallback
    }

    private func decidePasteAction() -> PasteDecision {
        guard accessibilityReader.hasPermission() else { return .fallback }
        guard !isCurrentAppFrontmost() else { return .retryOnce }
        guard let element = accessibilityReader.focusedElement() else { return .retryOnce }

        if classifier.isStrongVerificationField(element)
            || classifier.shouldPasteInVerificationContext(element)
            || classifier.shouldPasteAggressively(element) {
            return .pasteNow
        }

        if isBrowserContainer(element),
           accessibilityReader.findLoginButtonNearFocus(matcher: loginButtonMatcher) != nil {
            return .pasteNow
        }

        return .fallback
    }

    func openFullDiskAccessSettings() {
        SystemSettingsOpener.openFullDiskAccess()
    }

    func exportFocusDiagnostics() {
        recentAction = "诊断中：请立即切回浏览器点击验证码框（3秒）"
        notifyStateChanged()
        NSApp.hide(nil)

        let myPID = ProcessInfo.processInfo.processIdentifier
        var samples: [String] = []
        var validSampleCount = 0
        var skippedSampleCount = 0
        let totalSamples = 12

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            for index in 0..<totalSamples {
                let frontmost = NSWorkspace.shared.frontmostApplication
                let frontmostPID = frontmost?.processIdentifier ?? -1
                let frontmostBundle = frontmost?.bundleIdentifier ?? "nil"
                let frontmostName = frontmost?.localizedName ?? "nil"
                let isSelf = frontmostPID == myPID

                let snapshot = accessibilityReader.focusedElement()
                let decision = snapshot.map { classifier.isStrongVerificationField($0) } ?? false
                let contextDecision = snapshot.map { classifier.shouldPasteInVerificationContext($0) } ?? false
                let aggressiveDecision = snapshot.map { classifier.shouldPasteAggressively($0) } ?? false

                if isSelf {
                    skippedSampleCount += 1
                    samples.append("[\(index)] SKIPPED frontmost is self (\(frontmostName))")
                } else {
                    validSampleCount += 1
                    samples.append("[\(index)] VALID frontmost=\(frontmostName) bundle=\(frontmostBundle)")
                    samples.append(accessibilityReader.focusedElementDiagnostic())
                    samples.append("classifierDecision=\(decision)")
                    samples.append("shouldPasteInContext=\(contextDecision)")
                    samples.append("shouldPasteAggressively=\(aggressiveDecision)")
                    let loginButtonFound = accessibilityReader.findLoginButtonNearFocus(matcher: loginButtonMatcher) != nil
                    samples.append("loginButtonFound=\(loginButtonFound)")
                }
                samples.append("")

                if index < totalSamples - 1 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            writeFocusDiagnostics(
                samples: samples,
                validCount: validSampleCount,
                skippedCount: skippedSampleCount
            )
        }
    }

    func testPasteCode() {
        if copyAndPaste("123456", actionAfterPaste: "测试粘贴已发送") {
            recentAction = "准备测试粘贴"
            notifyStateChanged()
        }
    }

    func forceFillRecentCode() {
        guard let recentCode else {
            recentAction = "暂无最近验证码"
            notifyStateChanged()
            return
        }

        fillCodeManually(recentCode, prepareAction: "准备强制填入", doneAction: "已强制填入最近验证码")
    }

    func fillHistoryCode(at index: Int) {
        guard let code = codeHistory.code(at: index) else {
            recentAction = "历史验证码不存在"
            notifyStateChanged()
            return
        }

        recentCode = code
        fillCodeManually(code, prepareAction: "准备填入历史验证码", doneAction: "已填入历史验证码")
    }

    private func handleSmartFallbackHotKey() {
        guard accessibilityReader.hasPermission() else {
            recentAction = "请先授权辅助功能"
            notifyStateChanged()
            return
        }

        guard !isCurrentAppFrontmost(),
              let focusedElement = accessibilityReader.focusedElement() else {
            recentAction = "请先点击手机号框或验证码框"
            notifyStateChanged()
            return
        }

        if classifier.isAcceptableAccountField(focusedElement),
           !isVerificationEntryField(focusedElement) {
            let enabledAccounts = phoneAccounts.enabledAccounts
            if enabledAccounts.count == 1, let account = enabledAccounts.first {
                startLoginWithPhoneAccount(accountID: account.id)
            } else if enabledAccounts.isEmpty {
                recentAction = "请先添加手机号账号"
                notifyStateChanged()
            } else {
                recentAction = "请按账号快捷键：\(enabledAccounts.map { $0.shortcut.displayName }.joined(separator: " / "))"
                notifyStateChanged()
            }
            return
        }

        guard isVerificationEntryField(focusedElement) else {
            recentAction = "请先点击手机号框或验证码框"
            notifyStateChanged()
            return
        }

        guard let recentCode else {
            recentAction = "暂无最近验证码，等待短信"
            notifyStateChanged()
            return
        }

        fillCodeManually(recentCode, prepareAction: "快捷键触发：准备填入", doneAction: "快捷键触发：已填入")
    }

    private func isVerificationEntryField(_ snapshot: FocusedElementSnapshot) -> Bool {
        classifier.isStrongVerificationField(snapshot)
            || classifier.shouldPasteInVerificationContext(snapshot)
    }

    private func startLoginSession(anchor: AXUIElement?, context: AutomationTargetContext) {
        verificationRefocusTask?.cancel()
        verificationRefocusTask = nil

        let frontmost = NSWorkspace.shared.frontmostApplication
        let session = LoginAutomationSession(
            targetProcessID: frontmost?.processIdentifier,
            targetBundleIdentifier: frontmost?.bundleIdentifier,
            targetHost: automationSafetyPolicy.normalizedHost(from: context.urlString),
            phoneFieldAnchor: anchor
        )
        loginSession = session
        appendProcessLog("登录会话已创建 \(session.summary)")
    }

    private func activeLoginSession(now: Date = Date()) -> LoginAutomationSession? {
        guard let session = loginSession else { return nil }
        guard !session.isExpired(now: now) else {
            endLoginSession(reason: "登录会话已过期")
            return nil
        }
        return session
    }

    private func endLoginSession(reason: String) {
        if let session = loginSession {
            appendProcessLog("登录会话结束：\(reason); \(session.summary)")
        }
        verificationRefocusTask?.cancel()
        verificationRefocusTask = nil
        loginSession = nil
    }

    private func scheduleChromeBridgeCodeFill(_ code: String) -> Bool {
        guard let session = activeLoginSession(),
              session.targetBundleIdentifier == "com.google.Chrome" else {
            return false
        }

        verificationRefocusTask?.cancel()
        let commandID = chromeBridgeServer.enqueueVerificationCode(
            code: code,
            targetHost: session.targetHost,
            autoSubmit: isAutoClickLoginEnabled
        )
        appendProcessLog("已向 Chrome 扩展下发填码命令 command=\(commandID) host=\(session.targetHost ?? "nil")")
        recentAction = "短信到达：交给 Chrome 扩展填码"
        notifyStateChanged()

        verificationRefocusTask = Task { @MainActor in
            for attempt in 1...10 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)

                guard let result = self.chromeBridgeServer.result(sessionID: commandID) else {
                    continue
                }

                if result.filledCode == true {
                    let clickedLogin = result.clickedLogin == true
                    self.recentAction = clickedLogin
                        ? "Chrome 扩展已填码并点击登录"
                        : "Chrome 扩展已填码"
                    self.notifyStateChanged()
                    self.appendProcessLog("Chrome 扩展填码成功 attempt=\(attempt) clickedLogin=\(clickedLogin)")
                    if !clickedLogin {
                        self.scheduleAutoClickLogin()
                    }
                    self.endLoginSession(reason: "Chrome 扩展已回填验证码")
                    return
                }

                self.appendProcessLog("Chrome 扩展填码失败 attempt=\(attempt) status=\(result.status) message=\(result.message)")
                break
            }

            self.appendProcessLog("Chrome 扩展填码未完成，回退 App/剪贴板兜底")
            if self.tryFillPendingVerificationField(code) {
                return
            }
            if self.scheduleSessionRefocusAndFill(code) {
                return
            }
            self.tryAutoPaste(code)
        }

        return true
    }

    private func scheduleFocusedChromeBridgeCodeFill(_ code: String) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome",
              let focusedElement = accessibilityReader.focusedElement(),
              isVerificationEntryField(focusedElement) else {
            return false
        }

        let context = accessibilityReader.targetContext()
        let targetHost = automationSafetyPolicy.normalizedHost(from: context.urlString)
        let commandID = chromeBridgeServer.enqueueVerificationCode(
            code: code,
            targetHost: targetHost,
            autoSubmit: isAutoClickLoginEnabled
        )
        appendProcessLog("无会话 Chrome 焦点填码命令 command=\(commandID) host=\(targetHost ?? "nil")")
        recentAction = "短信到达：交给当前 Chrome 页面填码"
        notifyStateChanged()

        verificationRefocusTask?.cancel()
        verificationRefocusTask = Task { @MainActor in
            for attempt in 1...10 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)

                guard let result = self.chromeBridgeServer.result(sessionID: commandID) else {
                    continue
                }

                if result.filledCode == true {
                    let clickedLogin = result.clickedLogin == true
                    self.recentAction = clickedLogin
                        ? "Chrome 当前页已填码并点击登录"
                        : "Chrome 当前页已填码"
                    self.notifyStateChanged()
                    self.appendProcessLog("无会话 Chrome 填码成功 attempt=\(attempt) clickedLogin=\(clickedLogin)")
                    if !clickedLogin {
                        self.scheduleAutoClickLogin()
                    }
                    return
                }

                self.appendProcessLog("无会话 Chrome 填码失败 attempt=\(attempt) status=\(result.status) message=\(result.message)")
                break
            }

            self.appendProcessLog("无会话 Chrome 填码未完成，回退焦点/剪贴板")
            self.tryAutoPaste(code)
        }

        return true
    }

    private func tryFillPendingVerificationField(_ code: String) -> Bool {
        guard let session = activeLoginSession(),
              let field = verificationFieldLocator.cachedField(in: session) else {
            loginSession?.cachedVerificationField = nil
            return false
        }

        guard accessibilityReader.focusElement(field) else {
            loginSession?.cachedVerificationField = nil
            return false
        }

        endLoginSession(reason: "缓存验证码框已回填")
        fillCodeManually(code, prepareAction: "准备填入缓存验证码框", doneAction: "已填入缓存验证码框")
        return true
    }

    private func scheduleSessionRefocusAndFill(_ code: String) -> Bool {
        guard activeLoginSession() != nil else { return false }

        verificationRefocusTask?.cancel()
        recentAction = "短信到达：正在定位验证码框"
        notifyStateChanged()

        verificationRefocusTask = Task { @MainActor in
            for attempt in 1...10 {
                guard !Task.isCancelled else { return }

                if self.tryRefocusAndFillVerificationField(code) {
                    self.appendProcessLog("第 \(attempt) 次轮询定位验证码框成功")
                    return
                }

                if attempt < 10 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }

            self.appendProcessLog("验证码框 3 秒轮询超时，进入剪贴板兜底")
            self.endLoginSession(reason: "验证码框轮询超时")
            let copied = self.copyFallback(code)
            self.recentAction = copied ? "未找到验证码框，已复制到剪贴板" : "未找到验证码框，剪贴板写入失败"
            self.notifyStateChanged()
        }

        return true
    }

    private func tryRefocusAndFillVerificationField(_ code: String) -> Bool {
        guard accessibilityReader.hasPermission() else {
            return false
        }
        guard let session = activeLoginSession() else { return false }

        if let field = verificationFieldLocator.fieldNearSessionAnchor(session),
           accessibilityReader.focusElement(field) {
            endLoginSession(reason: "锚点重定位验证码框已回填")
            fillCodeManually(code, prepareAction: "短信到达：准备回到验证码框", doneAction: "短信到达：已填入验证码框")
            return true
        }

        if let field = verificationFieldLocator.fieldInTargetProcess(session),
           accessibilityReader.focusElement(field) {
            endLoginSession(reason: "目标进程重定位验证码框已回填")
            fillCodeManually(code, prepareAction: "短信到达：准备回到验证码框", doneAction: "短信到达：已填入验证码框")
            return true
        }

        guard !isCurrentAppFrontmost() else {
            return false
        }

        guard let field = verificationFieldLocator.fieldInCurrentContext(),
              accessibilityReader.focusElement(field) else {
            return false
        }

        endLoginSession(reason: "当前上下文重定位验证码框已回填")
        fillCodeManually(code, prepareAction: "短信到达：准备重定位验证码框", doneAction: "短信到达：已填入验证码框")
        return true
    }

    private func fillCodeManually(_ code: String, prepareAction: String, doneAction: String) {
        guard copyAndPaste(code, actionAfterPaste: doneAction) else {
            recentAction = "剪贴板写入失败，未自动粘贴"
            notifyStateChanged()
            return
        }
        recentAction = prepareAction
        notifyStateChanged()
        scheduleAutoClickLogin()
    }

    private func shouldTypeAutomatically() -> Bool {
        guard accessibilityReader.hasPermission(),
              !isCurrentAppFrontmost(),
              let element = accessibilityReader.focusedElement() else {
            return false
        }
        return classifier.isStrongVerificationField(element)
            || classifier.shouldPasteInVerificationContext(element)
            || classifier.shouldPasteAggressively(element)
    }

    private func isCurrentAppFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func isBrowserContainer(_ element: FocusedElementSnapshot) -> Bool {
        element.role == "AXWebArea" || element.role == "AXGroup"
    }

    @discardableResult
    private func copyFallback(_ code: String) -> Bool {
        let copied = copyLatestCodeToClipboard(code, context: "剪贴板兜底")
        if copied {
            notificationService.showClipboardFallback()
        }
        return copied
    }

    private func appendProcessLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let content = "[\(timestamp)] \(line)\n"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SmsCodeMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sms-processing.log")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func writeFocusDiagnostics(samples: [String], validCount: Int, skippedCount: Int) {
        let header = [
            "createdAt=\(ISO8601DateFormatter().string(from: Date()))",
            "accessibilityTrusted=\(AXIsProcessTrusted())",
            "myPID=\(ProcessInfo.processInfo.processIdentifier)",
            "totalSamples=\(samples.count)",
            "validSamples=\(validCount)",
            "skippedSamples=\(skippedCount)",
            "",
            "=== SAMPLES (每250ms一帧，共3秒) ===",
            ""
        ].joined(separator: "\n")

        let footer = [
            "",
            "=== END SAMPLES ===",
            "recentAction=\(recentAction)",
            "recentCodeLength=\(recentCode?.count.description ?? "nil")",
            "",
            "说明：VALID 行表示当时前台是别的 app（如浏览器），下面的 AX 信息是真实焦点。",
            "如果所有样本都是 SKIPPED，说明点击诊断后没有切回浏览器。",
            "请重新点诊断按钮，然后立刻切到浏览器点击验证码框。"
        ].joined(separator: "\n")

        let report = [header, samples.joined(separator: "\n"), footer].joined(separator: "\n")

        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/SmsCodeMenuBar", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("focus-diagnostics.txt")
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            lastDiagnosticFileURL = fileURL
            recentAction = "诊断已导出：\(validCount)个有效样本，\(skippedCount)个跳过"
        } catch {
            recentAction = "焦点诊断导出失败"
        }

        NSApp.unhide(nil)
        notifyStateChanged()
    }

    @discardableResult
    private func copyLatestCodeToClipboard(_ code: String, context: String) -> Bool {
        let copied = clipboard.copyTemporary(code)
        appendProcessLog("\(context)：剪贴板写入\(copied ? "成功" : "失败") code=\(CodeMasker.masked(code))")
        return copied
    }

    private func ensureClipboardContains(_ code: String, context: String) -> Bool {
        if clipboard.currentText() == code {
            return true
        }
        appendProcessLog("\(context)：剪贴板不是本次验证码，重新写入")
        return copyLatestCodeToClipboard(code, context: context)
    }

    @discardableResult
    private func copyAndPaste(_ code: String, actionAfterPaste: String) -> Bool {
        guard copyLatestCodeToClipboard(code, context: "自动粘贴前复制") else {
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard self.ensureClipboardContains(code, context: "自动粘贴前最终校验") else {
                self.recentAction = "剪贴板写入失败，未自动粘贴"
                self.notifyStateChanged()
                return
            }
            self.typer.paste()
            self.recentAction = actionAfterPaste
            self.notifyStateChanged()
        }
        return true
    }

    private func notifyStateChanged() {
        for observer in stateObservers {
            observer()
        }
    }
}

@MainActor
final class ShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var shortcut: KeyboardShortcutDescriptor?
    var onShortcutChanged: ((KeyboardShortcutDescriptor) -> Void)?

    init(initialShortcut: KeyboardShortcutDescriptor) {
        self.shortcut = initialShortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 64))

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.stringValue = "当前：\(initialShortcut.displayName)；点击后按新快捷键"
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        label.stringValue = "请按新的组合键"
    }

    override func keyDown(with event: NSEvent) {
        guard let descriptor = Self.shortcutDescriptor(from: event) else {
            label.stringValue = "快捷键需要包含 ⌘、⌥ 或 ⌃"
            shortcut = nil
            return
        }

        shortcut = descriptor
        label.stringValue = "已录制：\(descriptor.displayName)"
        onShortcutChanged?(descriptor)
    }

    private static func shortcutDescriptor(from event: NSEvent) -> KeyboardShortcutDescriptor? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            return nil
        }

        let modifierFlags = carbonModifierFlags(from: flags)
        guard modifierFlags != 0 else { return nil }

        return KeyboardShortcutDescriptor(
            keyCode: UInt32(event.keyCode),
            modifierFlags: modifierFlags,
            displayName: shortcutDisplayName(flags: flags, event: event)
        )
    }

    private static func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) {
            value |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            value |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            value |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            value |= UInt32(shiftKey)
        }
        return value
    }

    private static func shortcutDisplayName(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts: [String] = []
        if flags.contains(.control) {
            parts.append("⌃")
        }
        if flags.contains(.option) {
            parts.append("⌥")
        }
        if flags.contains(.shift) {
            parts.append("⇧")
        }
        if flags.contains(.command) {
            parts.append("⌘")
        }
        parts.append(keyName(from: event))
        return parts.joined()
    }

    private static func keyName(from event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return:
            return "↩"
        case kVK_Tab:
            return "⇥"
        case kVK_Space:
            return "Space"
        case kVK_Delete:
            return "⌫"
        case kVK_ForwardDelete:
            return "⌦"
        case kVK_Escape:
            return "Esc"
        default:
            break
        }

        if let raw = event.charactersIgnoringModifiers,
           let first = raw.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(first).uppercased()
        }
        return "#\(event.keyCode)"
    }
}
