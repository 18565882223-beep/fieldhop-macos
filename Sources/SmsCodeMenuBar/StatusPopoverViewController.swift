import AppKit

@MainActor
final class StatusPopoverViewController: NSViewController {
    private let coordinator: AppCoordinator
    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()
    private var isAccountsExpanded = true
    private var isEmailExpanded = true
    private var isSettingsExpanded = false
    private var isAllowlistExpanded = false
    private var isDebugExpanded = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 380, height: 640)
        coordinator.addStateObserver { [weak self] in
            self?.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: preferredContentSize.width),
            root.heightAnchor.constraint(equalToConstant: preferredContentSize.height),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        view = root
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }

        contentStack.arrangedSubviews.forEach { subview in
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        addHeader()
        addStatusRows()
        addSeparator()
        addDailyActions()
        addSeparator()
        addAccountsActions()
        addSeparator()
        addEmailActions()
        addSeparator()
        addSettingsActions()
        addSeparator()
        addButton("退出工具", action: #selector(quit), style: .destructive)
    }

    private func addHeader() {
        let title = NSTextField(labelWithString: "验证码助手")
        title.font = .boldSystemFont(ofSize: 18)
        contentStack.addArrangedSubview(title)
    }

    private func addStatusRows() {
        addInfo("状态", coordinator.recentAction)
        addInfo("最近验证码", coordinator.maskedRecentCode)
        addInfo("辅助功能", coordinator.hasAccessibilityPermission ? "已授权" : "未授权")
        addInfo("暂停状态", coordinator.pauseStatusTitle)
    }

    private func addDailyActions() {
        addSectionTitle("日常")
        addButton("用默认手机号获取验证码", action: #selector(startDefaultPhoneLogin))
        addButton(
            "复制最近验证码",
            action: #selector(copyRecentCode),
            isEnabled: coordinator.recentCode != nil
        )
        addButton(
            "强制填入最近验证码",
            action: #selector(forceFill),
            isEnabled: coordinator.recentCode != nil
        )

        if coordinator.isPaused {
            addButton("恢复监听", action: #selector(resumeListening))
        } else {
            addButton("暂停 10 分钟", action: #selector(pauseFor10Minutes))
            addButton("暂停 1 小时", action: #selector(pauseFor1Hour))
            addButton("无限暂停", action: #selector(pauseUntilManualResume))
        }
    }

    private func addAccountsActions() {
        addDisclosureButton(
            isAccountsExpanded ? "账号与快捷键 ▾" : "账号与快捷键 ▸",
            action: #selector(toggleAccountsSection)
        )
        guard isAccountsExpanded else { return }

        addInfo("账号数量", coordinator.phoneAccountSummary)
        for account in coordinator.phoneAccountItems {
            addInfo(account.name, account.shortcut.displayName)
            addButton(
                "使用 \(account.name)",
                action: #selector(startLoginWithPhoneAccount(_:)),
                identifier: account.id.uuidString
            )
            addButton(
                "修改 \(account.name) 的快捷键",
                action: #selector(setShortcutForPhoneAccount(_:)),
                identifier: account.id.uuidString
            )
            addButton(
                "删除 \(account.name)",
                action: #selector(removePhoneAccount(_:)),
                identifier: account.id.uuidString,
                style: .destructive
            )
        }

        addButton("设置默认手机号", action: #selector(setDefaultPhone))
        addButton("添加手机号账号", action: #selector(addPhoneAccount))
    }

    private func addEmailActions() {
        addDisclosureButton(
            isEmailExpanded ? "邮箱验证码 ▾" : "邮箱验证码 ▸",
            action: #selector(toggleEmailSection)
        )
        guard isEmailExpanded else { return }

        addInfo("当前状态", coordinator.emailWaitStatusTitle)
        if coordinator.isEmailMonitoringEnabled {
            addButton("取消等待", action: #selector(cancelEmailWaiting))
        }

        for account in coordinator.emailAccountItems {
            addButton(
                "\(account.shortcut.displayName)  \(account.displayName)  \(account.maskedEmail)",
                action: #selector(startEmailWaiting(_:)),
                isEnabled: account.isEnabled,
                identifier: account.id.uuidString
            )
        }
        addButton("管理邮箱账号…", action: #selector(showEmailManager))
    }

    private func addSettingsActions() {
        addDisclosureButton(
            isSettingsExpanded ? "设置与白名单 ▾" : "设置与白名单 ▸",
            action: #selector(toggleSettingsSection)
        )
        guard isSettingsExpanded else {
            addDisclosureButton(
                isDebugExpanded ? "调试 ▾" : "调试 ▸",
                action: #selector(toggleDebugSection)
            )
            if isDebugExpanded {
                addDebugActions()
            }
            return
        }

        addInfo("自动点击登录", coordinator.autoClickModeTitle)
        addInfo("发送前自动勾协议", coordinator.autoCheckRequiredAgreementTitle)
        addInfo("开机自启", coordinator.isLaunchAtLoginEnabled ? "已开启" : "未开启")
        addButton("切换自动点击登录", action: #selector(toggleAutoClick))
        addButton("发送前自动勾协议", action: #selector(toggleAutoCheckRequiredAgreement))
        addButton("把当前网页/App 加入白名单", action: #selector(trustCurrentTargetForAutoClick))
        addDisclosureButton(
            isAllowlistExpanded ? "查看白名单 ▾" : "查看白名单 ▸",
            action: #selector(toggleAllowlistSection)
        )
        if isAllowlistExpanded {
            addAllowlistActions()
        }
        addButton(
            coordinator.isLaunchAtLoginEnabled ? "关闭开机自启" : "开启开机自启",
            action: #selector(toggleLaunchAtLogin)
        )
        addButton(
            coordinator.hasAccessibilityPermission ? "重新打开辅助功能授权" : "打开辅助功能授权",
            action: #selector(openAccessibility)
        )
        addButton("打开完全磁盘访问设置", action: #selector(openFullDiskAccess))
        addDisclosureButton(
            isDebugExpanded ? "调试 ▾" : "调试 ▸",
            action: #selector(toggleDebugSection)
        )
        if isDebugExpanded {
            addDebugActions()
        }
    }

    private func addAllowlistActions() {
        let entries = coordinator.allowlistEntries
        guard !entries.isEmpty else {
            addInfo("白名单", "空")
            return
        }

        for entry in entries {
            addInfo(entry.subtitle, entry.title)
            addButton(
                "移除 \(entry.title)",
                action: #selector(removeAllowlistEntry(_:)),
                identifier: entry.id,
                style: .destructive
            )
        }
    }

    private func addDebugActions() {
        addButton("3秒后导出焦点诊断", action: #selector(exportDiagnostics))
        addButton("测试粘贴 123456", action: #selector(testPaste))
    }

    private func addSectionTitle(_ title: String) {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: 14)
        field.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(field)
    }

    private func addDisclosureButton(_ title: String, action: Selector) {
        addButton(title, action: action)
    }

    private func addInfo(_ label: String, _ value: String) {
        let field = NSTextField(labelWithString: "\(label)：\(value)")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        contentStack.addArrangedSubview(field)
    }

    private enum ButtonStyle {
        case normal
        case destructive
    }

    private func addButton(
        _ title: String,
        action: Selector,
        isEnabled: Bool = true,
        identifier: String? = nil,
        style: ButtonStyle = .normal
    ) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isEnabled = isEnabled
        button.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        if let identifier {
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        if style == .destructive {
            button.contentTintColor = .systemRed
        }
        contentStack.addArrangedSubview(button)
    }

    private func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 340).isActive = true
        contentStack.addArrangedSubview(separator)
    }

    @objc private func exportDiagnostics() {
        coordinator.exportFocusDiagnostics()
        refresh()
    }

    @objc private func testPaste() {
        coordinator.testPasteCode()
        refresh()
    }

    @objc private func copyRecentCode() {
        coordinator.copyRecentCode()
        refresh()
    }

    @objc private func forceFill() {
        coordinator.forceFillRecentCode()
        refresh()
    }

    @objc private func toggleAutoClick() {
        coordinator.toggleAutoClickLogin()
        refresh()
    }

    @objc private func trustCurrentTargetForAutoClick() {
        coordinator.trustCurrentTargetForAutoClick()
        refresh()
    }

    @objc private func toggleAutoCheckRequiredAgreement() {
        coordinator.toggleAutoCheckRequiredAgreement()
        refresh()
    }

    @objc private func pauseFor10Minutes() {
        coordinator.pauseFor(minutes: 10)
        refresh()
    }

    @objc private func pauseFor1Hour() {
        coordinator.pauseFor(minutes: 60)
        refresh()
    }

    @objc private func pauseUntilManualResume() {
        coordinator.pauseUntilManualResume()
        refresh()
    }

    @objc private func resumeListening() {
        coordinator.resumeListening()
        refresh()
    }

    @objc private func setDefaultPhone() {
        coordinator.promptAndSaveDefaultPhoneNumber()
        refresh()
    }

    @objc private func addPhoneAccount() {
        coordinator.promptAndAddPhoneAccount()
        refresh()
    }

    @objc private func addEmailAccount() {
        coordinator.promptAndAddEmailAccount()
        refresh()
    }

    @objc private func toggleEmailMonitoring() {
        coordinator.toggleEmailMonitoring()
        refresh()
    }

    @objc private func testEmailConnection(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let accountID = UUID(uuidString: rawValue) else { return }
        coordinator.testEmailConnection(id: accountID)
        refresh()
    }

    @objc private func toggleEmailAccount(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let accountID = UUID(uuidString: rawValue) else { return }
        coordinator.toggleEmailAccount(id: accountID)
        refresh()
    }

    @objc private func removeEmailAccount(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let accountID = UUID(uuidString: rawValue) else { return }
        coordinator.removeEmailAccount(id: accountID)
        refresh()
    }

    @objc private func setShortcutForPhoneAccount(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let accountID = UUID(uuidString: rawValue) else {
            return
        }
        coordinator.promptAndSetShortcutForPhoneAccount(id: accountID)
        refresh()
    }

    @objc private func removePhoneAccount(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let accountID = UUID(uuidString: rawValue) else {
            return
        }
        coordinator.removePhoneAccount(id: accountID)
        refresh()
    }

    @objc private func removeAllowlistEntry(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue else {
            return
        }
        coordinator.removeAllowlistEntry(id: rawValue)
        refresh()
    }

    @objc private func toggleAccountsSection() {
        isAccountsExpanded.toggle()
        refresh()
    }

    @objc private func toggleEmailSection() {
        isEmailExpanded.toggle()
        refresh()
    }

    @objc private func startEmailWaiting(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue, let id = UUID(uuidString: rawValue) else { return }
        coordinator.startEmailWaiting(accountID: id)
        refresh()
    }

    @objc private func cancelEmailWaiting() {
        coordinator.cancelEmailWaiting()
        refresh()
    }

    @objc private func showEmailManager() {
        coordinator.showEmailAccountManager()
        refresh()
    }

    @objc private func toggleSettingsSection() {
        isSettingsExpanded.toggle()
        refresh()
    }

    @objc private func toggleAllowlistSection() {
        isAllowlistExpanded.toggle()
        refresh()
    }

    @objc private func toggleDebugSection() {
        isDebugExpanded.toggle()
        refresh()
    }

    @objc private func startLoginWithPhoneAccount(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let accountID = UUID(uuidString: rawValue) else {
            return
        }
        coordinator.startLoginWithPhoneAccount(accountID: accountID)
        refresh()
    }

    @objc private func startDefaultPhoneLogin() {
        coordinator.startLoginWithDefaultPhoneNumber()
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        coordinator.toggleLaunchAtLogin()
        refresh()
    }

    @objc private func openAccessibility() {
        coordinator.requestAccessibilityPermission()
        refresh()
    }

    @objc private func openFullDiskAccess() {
        coordinator.openFullDiskAccessSettings()
        refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
