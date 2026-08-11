import AppKit
import SmsCodeCore

struct EmailAccountManagerResult: Equatable {
    let isSuccess: Bool
    let message: String

    static func success(_ message: String) -> EmailAccountManagerResult {
        EmailAccountManagerResult(isSuccess: true, message: message)
    }

    static func failure(_ message: String) -> EmailAccountManagerResult {
        EmailAccountManagerResult(isSuccess: false, message: message)
    }
}

@MainActor
final class EmailAccountManagerController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias AddHandler = () -> Void
    typealias SaveHandler = (EmailAccount) -> EmailAccountManagerResult
    typealias DeleteHandler = (UUID) -> EmailAccountManagerResult
    typealias TestHandler = (UUID, @escaping (String) -> Void) -> Void
    typealias StatusProvider = (UUID) -> EmailConnectionStatus
    typealias ShortcutConflictProvider = (KeyboardShortcutDescriptor, UUID) -> String?
    typealias ShortcutAvailabilityProvider = (KeyboardShortcutDescriptor) -> Bool

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let addButton = NSButton(title: "添加账号", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "请选择左侧邮箱账号")
    private let formStack = NSStackView()
    private let nameField = NSTextField()
    private let maskedEmailLabel = NSTextField(labelWithString: "")
    private let emailField = NSTextField()
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcutContainer = NSView()
    private let waitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let enabledButton = NSButton(checkboxWithTitle: "启用此账号", target: nil, action: nil)
    private let usernameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let tlsButton = NSButton(checkboxWithTitle: "启用 TLS", target: nil, action: nil)
    private let advancedButton = NSButton(title: "高级设置 ▸", target: nil, action: nil)
    private let advancedStack = NSStackView()
    private let diagnosticsButton = NSButton(title: "诊断信息 ▸", target: nil, action: nil)
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let copyDiagnosticButton = NSButton(title: "复制诊断信息", target: nil, action: nil)
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)

    private let addHandler: AddHandler
    private let saveHandler: SaveHandler
    private let deleteHandler: DeleteHandler
    private let testHandler: TestHandler
    private let statusProvider: StatusProvider
    private let shortcutConflictProvider: ShortcutConflictProvider
    private let shortcutAvailabilityProvider: ShortcutAvailabilityProvider
    private let confirmsDeletion: Bool

    private var accounts: [EmailAccount]
    private var selectedAccountID: UUID?
    private var shortcutRecorder: ShortcutRecorderView?
    private var advancedExpanded = false
    private var diagnosticsExpanded = false

    var contentViewForTesting: NSView? {
        panel.contentView
    }

    var messageForTesting: String {
        messageLabel.stringValue
    }

    var accountsForTesting: [EmailAccount] {
        accounts
    }

    init(
        accounts: [EmailAccount],
        statusProvider: @escaping StatusProvider,
        addHandler: @escaping AddHandler,
        saveHandler: @escaping SaveHandler,
        deleteHandler: @escaping DeleteHandler,
        testHandler: @escaping TestHandler,
        shortcutConflictProvider: @escaping ShortcutConflictProvider,
        shortcutAvailabilityProvider: @escaping ShortcutAvailabilityProvider,
        confirmsDeletion: Bool = true
    ) {
        self.accounts = accounts
        self.statusProvider = statusProvider
        self.addHandler = addHandler
        self.saveHandler = saveHandler
        self.deleteHandler = deleteHandler
        self.testHandler = testHandler
        self.shortcutConflictProvider = shortcutConflictProvider
        self.shortcutAvailabilityProvider = shortcutAvailabilityProvider
        self.confirmsDeletion = confirmsDeletion
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        reload(accounts: accounts, keepSelection: true)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func reload(accounts newAccounts: [EmailAccount], keepSelection: Bool) {
        accounts = newAccounts
        if keepSelection, let selectedAccountID, accounts.contains(where: { $0.id == selectedAccountID }) {
            self.selectedAccountID = selectedAccountID
        } else {
            selectedAccountID = accounts.first?.id
        }
        tableView.reloadData()
        selectCurrentRow()
        loadSelectedAccount()
    }

    func refreshDiagnostics() {
        updateDiagnostics()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        accounts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("email-manager-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        if label.superview == nil {
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let account = accounts[row]
        label.stringValue = "\(account.displayName)  \(account.maskedEmail)"
        label.font = .systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < accounts.count else {
            selectedAccountID = nil
            loadSelectedAccount()
            return
        }
        selectedAccountID = accounts[tableView.selectedRow].id
        loadSelectedAccount()
    }

    @objc private func addAccount() {
        addHandler()
    }

    @objc private func saveAccount() {
        guard var account = selectedAccountFromFields() else { return }
        guard validateShortcut(account.shortcut, accountID: account.id) else { return }
        account.waitDurationMinutes = selectedWaitMinutes()
        let result = saveHandler(account)
        setMessage(result.message, copyable: !result.isSuccess)
        if result.isSuccess {
            reload(accounts: replacing(account), keepSelection: true)
        }
    }

    @objc private func deleteAccount() {
        guard let account = selectedAccount() else { return }
        if confirmsDeletion {
            let alert = NSAlert()
            alert.messageText = "删除邮箱账号"
            alert.informativeText = "将删除 \(account.maskedEmail) 的账号配置和本机保存的授权码。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let result = deleteHandler(account.id)
        setMessage(result.message, copyable: !result.isSuccess)
        if result.isSuccess {
            reload(accounts: accounts.filter { $0.id != account.id }, keepSelection: false)
        }
    }

    @objc private func testConnection() {
        guard let account = selectedAccount() else { return }
        setMessage("正在测试 \(account.maskedEmail)…", copyable: false)
        testButton.isEnabled = false
        testHandler(account.id) { [weak self] message in
            guard let self else { return }
            self.setMessage(
                message,
                copyable: message.contains("失败") || message.contains("CAPABILITY") || message.contains("\n")
            )
            self.testButton.isEnabled = true
            self.updateDiagnostics()
        }
    }

    @objc private func copyDiagnostic() {
        let text = messageLabel.stringValue
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func providerChanged() {
        let preset = EmailProviderPreset.allCases[providerPopup.indexOfSelectedItem]
        guard preset != .custom else { return }
        hostField.stringValue = preset.host
        portField.stringValue = String(preset.port)
        tlsButton.state = preset.useTLS ? .on : .off
    }

    @objc private func toggleAdvanced() {
        advancedExpanded.toggle()
        advancedStack.isHidden = !advancedExpanded
        advancedButton.title = advancedExpanded ? "高级设置 ▾" : "高级设置 ▸"
    }

    @objc private func toggleDiagnostics() {
        diagnosticsExpanded.toggle()
        diagnosticsLabel.isHidden = !diagnosticsExpanded
        diagnosticsButton.title = diagnosticsExpanded ? "诊断信息 ▾" : "诊断信息 ▸"
        updateDiagnostics()
    }

    private func buildWindow() {
        panel.title = "管理邮箱账号"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 760, height: 520)
        panel.delegate = self

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let leftPane = buildLeftPane()
        let rightPane = buildRightPane()
        content.addSubview(leftPane)
        content.addSubview(rightPane)

        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftPane.topAnchor.constraint(equalTo: content.topAnchor),
            leftPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            leftPane.widthAnchor.constraint(equalToConstant: 250),
            rightPane.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightPane.topAnchor.constraint(equalTo: content.topAnchor),
            rightPane.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func buildLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "邮箱账号")
        title.font = .boldSystemFont(ofSize: 15)
        title.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("email-manager-account-column"))
        column.title = "账号"
        tableView.identifier = NSUserInterfaceItemIdentifier("email-manager-account-table")
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = false
        scrollView.documentView = tableView

        addButton.identifier = NSUserInterfaceItemIdentifier("email-manager-add")
        addButton.target = self
        addButton.action = #selector(addAccount)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(scrollView)
        container.addSubview(addButton)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        return container
    }

    private func buildRightPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 12
        formStack.translatesAutoresizingMaskIntoConstraints = false

        configureField(nameField, identifier: "email-manager-name", placeholder: "显示名称")
        configureField(emailField, identifier: "email-manager-email", placeholder: "name@example.com")
        configureField(usernameField, identifier: "email-manager-username", placeholder: "IMAP 用户名")
        configureField(hostField, identifier: "email-manager-host", placeholder: "imap.example.com")
        configureField(portField, identifier: "email-manager-port", placeholder: "993")
        maskedEmailLabel.identifier = NSUserInterfaceItemIdentifier("email-manager-masked-email")
        maskedEmailLabel.textColor = .secondaryLabelColor

        providerPopup.identifier = NSUserInterfaceItemIdentifier("email-manager-provider")
        providerPopup.addItems(withTitles: EmailProviderPreset.allCases.map(\.title))
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        waitPopup.identifier = NSUserInterfaceItemIdentifier("email-manager-wait")
        waitPopup.addItems(withTitles: ["5 分钟", "10 分钟", "15 分钟"])

        enabledButton.identifier = NSUserInterfaceItemIdentifier("email-manager-enabled")
        tlsButton.identifier = NSUserInterfaceItemIdentifier("email-manager-tls")

        advancedButton.identifier = NSUserInterfaceItemIdentifier("email-manager-advanced-toggle")
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced)
        advancedButton.bezelStyle = .inline
        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 10
        advancedStack.isHidden = true
        advancedStack.addArrangedSubview(row(label: "IMAP 用户名", view: usernameField))
        advancedStack.addArrangedSubview(row(label: "主机", view: hostField))
        advancedStack.addArrangedSubview(row(label: "端口", view: portField))
        advancedStack.addArrangedSubview(row(label: "TLS", view: tlsButton))

        diagnosticsButton.identifier = NSUserInterfaceItemIdentifier("email-manager-diagnostics-toggle")
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(toggleDiagnostics)
        diagnosticsButton.bezelStyle = .inline
        diagnosticsLabel.identifier = NSUserInterfaceItemIdentifier("email-manager-diagnostics")
        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.maximumNumberOfLines = 5
        diagnosticsLabel.isSelectable = true
        diagnosticsLabel.isHidden = true

        testButton.identifier = NSUserInterfaceItemIdentifier("email-manager-test")
        testButton.target = self
        testButton.action = #selector(testConnection)
        saveButton.identifier = NSUserInterfaceItemIdentifier("email-manager-save")
        saveButton.target = self
        saveButton.action = #selector(saveAccount)
        saveButton.keyEquivalent = "\r"
        deleteButton.identifier = NSUserInterfaceItemIdentifier("email-manager-delete")
        deleteButton.target = self
        deleteButton.action = #selector(deleteAccount)

        messageLabel.identifier = NSUserInterfaceItemIdentifier("email-manager-message")
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isSelectable = true
        copyDiagnosticButton.identifier = NSUserInterfaceItemIdentifier("email-manager-copy-diagnostic")
        copyDiagnosticButton.target = self
        copyDiagnosticButton.action = #selector(copyDiagnostic)
        copyDiagnosticButton.isHidden = true

        let buttons = NSStackView(views: [deleteButton, NSView(), testButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: 520).isActive = true

        formStack.addArrangedSubview(row(label: "显示名称", view: nameField))
        formStack.addArrangedSubview(row(label: "脱敏邮箱", view: maskedEmailLabel))
        formStack.addArrangedSubview(row(label: "邮箱地址", view: emailField))
        formStack.addArrangedSubview(row(label: "服务商", view: providerPopup))
        formStack.addArrangedSubview(row(label: "快捷键", view: shortcutContainer))
        formStack.addArrangedSubview(row(label: "默认等待", view: waitPopup))
        formStack.addArrangedSubview(row(label: "状态", view: enabledButton))
        formStack.addArrangedSubview(advancedButton)
        formStack.addArrangedSubview(advancedStack)
        formStack.addArrangedSubview(diagnosticsButton)
        formStack.addArrangedSubview(diagnosticsLabel)
        formStack.addArrangedSubview(messageLabel)
        formStack.addArrangedSubview(copyDiagnosticButton)
        formStack.addArrangedSubview(buttons)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = formStack

        container.addSubview(emptyLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        ])
        return container
    }

    private func loadSelectedAccount() {
        guard let account = selectedAccount() else {
            emptyLabel.isHidden = false
            formStack.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        formStack.isHidden = false
        nameField.stringValue = account.displayName
        maskedEmailLabel.stringValue = account.maskedEmail
        emailField.stringValue = account.emailAddress
        usernameField.stringValue = account.username
        hostField.stringValue = account.host
        portField.stringValue = String(account.port)
        tlsButton.state = account.useTLS ? .on : .off
        enabledButton.state = account.isEnabled ? .on : .off
        selectProvider(for: account)
        waitPopup.selectItem(withTitle: "\(account.waitDurationMinutes) 分钟")
        installShortcutRecorder(account.shortcut)
        setMessage("", copyable: false)
        updateDiagnostics()
    }

    private func installShortcutRecorder(_ shortcut: KeyboardShortcutDescriptor) {
        shortcutContainer.subviews.forEach { $0.removeFromSuperview() }
        shortcutContainer.translatesAutoresizingMaskIntoConstraints = false
        if !shortcutContainer.constraints.contains(where: { $0.firstAttribute == .width }) {
            shortcutContainer.widthAnchor.constraint(equalToConstant: 330).isActive = true
            shortcutContainer.heightAnchor.constraint(equalToConstant: 64).isActive = true
        }
        let recorder = ShortcutRecorderView(initialShortcut: shortcut)
        recorder.identifier = NSUserInterfaceItemIdentifier("email-manager-shortcut")
        recorder.onShortcutChanged = { [weak self] shortcut in
            guard let self, let account = self.selectedAccount() else { return }
            _ = self.validateShortcut(shortcut, accountID: account.id, onlyWarn: true)
        }
        recorder.translatesAutoresizingMaskIntoConstraints = false
        shortcutContainer.addSubview(recorder)
        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: shortcutContainer.leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: shortcutContainer.trailingAnchor),
            recorder.topAnchor.constraint(equalTo: shortcutContainer.topAnchor),
            recorder.bottomAnchor.constraint(equalTo: shortcutContainer.bottomAnchor)
        ])
        shortcutRecorder = recorder
    }

    private func selectedAccountFromFields() -> EmailAccount? {
        guard let original = selectedAccount() else { return nil }
        let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            setMessage("显示名称不能为空", copyable: false)
            return nil
        }
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else {
            setMessage("请输入有效邮箱地址", copyable: false)
            return nil
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else {
            setMessage("请输入有效 IMAP 主机", copyable: false)
            return nil
        }
        guard let port = Int(portField.stringValue), (1...65_535).contains(port) else {
            setMessage("IMAP 端口必须是 1–65535", copyable: false)
            return nil
        }
        guard tlsButton.state == .on else {
            setMessage("安全规则要求启用 TLS", copyable: false)
            return nil
        }
        guard let shortcut = shortcutRecorder?.shortcut else {
            setMessage("请先录制快捷键", copyable: false)
            return nil
        }

        var account = original
        let mailboxChanged = account.emailAddress != email
            || account.username != (username.isEmpty ? email : username)
            || account.host != host.lowercased()
            || account.port != port
            || account.useTLS != true
        account.displayName = displayName
        account.emailAddress = email
        account.username = username.isEmpty ? email : username
        account.host = host.lowercased()
        account.port = port
        account.useTLS = true
        account.isEnabled = enabledButton.state == .on
        account.shortcut = shortcut
        account.waitDurationMinutes = selectedWaitMinutes()
        if mailboxChanged {
            account.uidValidity = nil
            account.lastSeenUID = nil
        }
        return account
    }

    private func validateShortcut(
        _ shortcut: KeyboardShortcutDescriptor,
        accountID: UUID,
        onlyWarn: Bool = false
    ) -> Bool {
        if let conflictName = shortcutConflictProvider(shortcut, accountID) {
            setMessage("\(shortcut.displayName) 已被 \(conflictName) 使用", copyable: false)
            return false
        }
        if selectedAccount()?.shortcut != shortcut, !shortcutAvailabilityProvider(shortcut) {
            setMessage("\(shortcut.displayName) 已被系统或其他 App 占用", copyable: false)
            return false
        }
        if onlyWarn {
            setMessage("已录制：\(shortcut.displayName)", copyable: false)
        }
        return true
    }

    private func selectedWaitMinutes() -> Int {
        switch waitPopup.indexOfSelectedItem {
        case 0: return 5
        case 2: return 15
        default: return 10
        }
    }

    private func setMessage(_ message: String, copyable: Bool) {
        messageLabel.stringValue = message
        copyDiagnosticButton.isHidden = !copyable || message.isEmpty
    }

    private func updateDiagnostics() {
        guard let account = selectedAccount() else {
            diagnosticsLabel.stringValue = "尚无监听诊断"
            return
        }
        let status = statusProvider(account.id)
        diagnosticsLabel.stringValue = "\(status.displayText)\n\(status.diagnosticText)"
    }

    private func selectedAccount() -> EmailAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }

    private func replacing(_ account: EmailAccount) -> [EmailAccount] {
        accounts.map { $0.id == account.id ? account : $0 }
    }

    private func selectCurrentRow() {
        guard let selectedAccountID,
              let index = accounts.firstIndex(where: { $0.id == selectedAccountID }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func selectProvider(for account: EmailAccount) {
        let preset = EmailProviderPreset.allCases.first { preset in
            preset != .custom && preset.host == account.host
        } ?? .custom
        if let index = EmailProviderPreset.allCases.firstIndex(of: preset) {
            providerPopup.selectItem(at: index)
        }
    }

    private func configureField(_ field: NSTextField, identifier: String, placeholder: String) {
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func row(label text: String, view: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        let stack = NSStackView(views: [label, view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return stack
    }
}
