import AppKit
import SmsCodeCore

struct EmailAccountDraft {
    let account: EmailAccount
    let password: String
}

enum EmailAccountSheetSaveResult: Equatable {
    case success
    case failure(String)
}

enum EmailAccountFormError: Error, LocalizedError {
    case invalidEmail
    case missingPassword
    case invalidHost
    case invalidPort
    case tlsRequired

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "请输入有效的邮箱地址"
        case .missingPassword: return "请输入应用专用密码或授权码"
        case .invalidHost: return "请输入有效的 IMAP 主机"
        case .invalidPort: return "IMAP 端口必须是 1–65535"
        case .tlsRequired: return "安全规则要求启用 TLS"
        }
    }
}

@MainActor
final class AuthorizationCodeSecureField: NSSecureTextField {
    var sanitizedStringValue: String {
        currentSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var currentSecret: String {
        currentEditor()?.string ?? stringValue
    }

    func pasteSanitizedAuthorizationCode() {
        guard let rawText = NSPasteboard.general.string(forType: .string) else {
            return
        }
        let sanitized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editor = currentEditor() {
            editor.insertText(sanitized)
        } else {
            stringValue = sanitized
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteSanitizedAuthorizationCode()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class HoldRevealButton: NSButton {
    var onPressChanged: ((Bool) -> Void)?

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        bezelStyle = .rounded
        controlSize = .small
    }

    override func mouseDown(with event: NSEvent) {
        onPressChanged?(true)
    }

    override func mouseUp(with event: NSEvent) {
        onPressChanged?(false)
    }

    override func mouseExited(with event: NSEvent) {
        onPressChanged?(false)
    }
}

@MainActor
final class EmailAccountFormView: NSView {
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let emailField = NSTextField()
    private let passwordField = AuthorizationCodeSecureField()
    private let passwordVisibleField = NSTextField()
    private let passwordRevealButton = HoldRevealButton(title: "显示")
    private let passwordContainer = NSView()
    private let providerHintLabel = NSTextField(wrappingLabelWithString: "")
    private let usernameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let tlsButton = NSButton(checkboxWithTitle: "启用 TLS（必选）", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("email-account-form")

        presetPopup.addItems(withTitles: EmailProviderPreset.allCases.map(\.title))
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        presetPopup.identifier = NSUserInterfaceItemIdentifier("email-account-preset")

        configure(nameField, identifier: "email-account-name", placeholder: "例如：工作 Gmail")
        configure(emailField, identifier: "email-account-address", placeholder: "name@example.com")
        configure(passwordField, identifier: "email-account-password", placeholder: "应用专用密码 / 授权码（不是邮箱主密码）")
        configure(passwordVisibleField, identifier: "email-account-password-visible", placeholder: "应用专用密码 / 授权码（不是邮箱主密码）")
        configurePasswordControls()
        providerHintLabel.identifier = NSUserInterfaceItemIdentifier("email-account-provider-hint")
        providerHintLabel.textColor = .secondaryLabelColor
        providerHintLabel.font = .systemFont(ofSize: 12)
        configure(usernameField, identifier: "email-account-username", placeholder: "通常与邮箱地址相同")
        configure(hostField, identifier: "email-account-host", placeholder: "imap.example.com")
        configure(portField, identifier: "email-account-port", placeholder: "993")
        portField.stringValue = "993"
        tlsButton.state = .on
        tlsButton.identifier = NSUserInterfaceItemIdentifier("email-account-tls")

        let grid = NSGridView(views: [
            [label("服务商"), presetPopup],
            [label("显示名"), nameField],
            [label("邮箱地址"), emailField],
            [label("应用专用密码"), passwordContainer],
            [label("提示"), providerHintLabel],
            [label("IMAP 用户名"), usernameField],
            [label("IMAP 主机"), hostField],
            [label("端口"), portField],
            [label("传输安全"), tlsButton]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).width = 104
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 440
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 8).yPlacement = .center
        addSubview(grid)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 556),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        selectPreset(.gmail)
        configureTabOrder(endingWith: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectPreset(_ preset: EmailProviderPreset) {
        guard let index = EmailProviderPreset.allCases.firstIndex(of: preset) else { return }
        presetPopup.selectItem(at: index)
        applyPreset(preset)
    }

    func configureTabOrder(endingWith lastView: NSView?) {
        presetPopup.nextKeyView = nameField
        nameField.nextKeyView = emailField
        emailField.nextKeyView = passwordField
        passwordField.nextKeyView = usernameField
        usernameField.nextKeyView = hostField
        hostField.nextKeyView = portField
        portField.nextKeyView = tlsButton
        tlsButton.nextKeyView = lastView
    }

    func makeDraft() throws -> EmailAccountDraft {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !email.hasPrefix("@"), !email.hasSuffix("@") else {
            throw EmailAccountFormError.invalidEmail
        }
        let password = passwordField.sanitizedStringValue
        guard !password.isEmpty else { throw EmailAccountFormError.missingPassword }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else {
            throw EmailAccountFormError.invalidHost
        }
        guard let port = Int(portField.stringValue), (1...65_535).contains(port) else {
            throw EmailAccountFormError.invalidPort
        }
        guard tlsButton.state == .on else { throw EmailAccountFormError.tlsRequired }

        let selectedPreset = EmailProviderPreset.allCases[presetPopup.indexOfSelectedItem]
        let defaultName = selectedPreset == .custom ? "邮箱验证码" : selectedPreset.title
        let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmailAccountDraft(
            account: EmailAccount(
                displayName: displayName.isEmpty ? defaultName : displayName,
                emailAddress: email,
                host: host,
                port: port,
                useTLS: true,
                username: username.isEmpty ? email : username
            ),
            password: password
        )
    }

    @objc private func presetChanged() {
        applyPreset(EmailProviderPreset.allCases[presetPopup.indexOfSelectedItem])
    }

    private func applyPreset(_ preset: EmailProviderPreset) {
        if preset != .custom {
            hostField.stringValue = preset.host
            portField.stringValue = String(preset.port)
            tlsButton.state = preset.useTLS ? .on : .off
        }
        if preset == .perfect88 {
            providerHintLabel.stringValue = "建议参数，连接成功前未验证。请在 88 邮箱“设置 → 客户端设置 → 配置帮助”核对 IMAP 服务与专用密码/授权码。"
        } else {
            providerHintLabel.stringValue = "请填写应用专用密码或授权码，不要填写邮箱主密码。"
        }
    }

    private func configure(_ field: NSTextField, identifier: String, placeholder: String) {
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configurePasswordControls() {
        passwordVisibleField.isHidden = true
        passwordVisibleField.isEditable = false
        passwordVisibleField.isSelectable = false
        passwordRevealButton.identifier = NSUserInterfaceItemIdentifier("email-account-password-reveal")
        passwordRevealButton.onPressChanged = { [weak self] isPressed in
            self?.setPasswordRevealed(isPressed)
        }

        passwordContainer.translatesAutoresizingMaskIntoConstraints = false
        [passwordField, passwordVisibleField, passwordRevealButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            passwordContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            passwordContainer.heightAnchor.constraint(equalToConstant: 26),
            passwordField.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: passwordRevealButton.leadingAnchor, constant: -8),
            passwordField.centerYAnchor.constraint(equalTo: passwordContainer.centerYAnchor),
            passwordVisibleField.leadingAnchor.constraint(equalTo: passwordField.leadingAnchor),
            passwordVisibleField.trailingAnchor.constraint(equalTo: passwordField.trailingAnchor),
            passwordVisibleField.centerYAnchor.constraint(equalTo: passwordField.centerYAnchor),
            passwordRevealButton.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor),
            passwordRevealButton.centerYAnchor.constraint(equalTo: passwordContainer.centerYAnchor),
            passwordRevealButton.widthAnchor.constraint(equalToConstant: 58)
        ])
    }

    func concealPasswordForTesting() {
        setPasswordRevealed(false)
    }

    private func setPasswordRevealed(_ isRevealed: Bool) {
        if isRevealed {
            passwordVisibleField.stringValue = passwordField.currentSecret
        } else {
            passwordVisibleField.stringValue = ""
        }
        passwordField.isHidden = isRevealed
        passwordVisibleField.isHidden = !isRevealed
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.font = .systemFont(ofSize: 13)
        return field
    }
}

@MainActor
final class EmailAccountSheetController: NSObject, NSWindowDelegate {
    typealias SubmitHandler = (EmailAccountDraft, @escaping @MainActor (EmailAccountSheetSaveResult) -> Void) -> Void

    private let panel: NSPanel
    private let form = EmailAccountFormView(frame: .zero)
    private let validationLabel = NSTextField(labelWithString: "")
    private let copyDiagnosticButton = NSButton(title: "复制诊断信息", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let saveButton = NSButton(title: "测试并保存", target: nil, action: nil)
    private var submittedDraft: EmailAccountDraft?
    private var isRunningModally = false
    private let submitHandler: SubmitHandler?

    var contentSizeForTesting: NSSize {
        panel.contentView?.bounds.size ?? .zero
    }

    var contentViewForTesting: NSView? {
        panel.contentView
    }

    var submittedDraftForTesting: EmailAccountDraft? {
        submittedDraft
    }

    init(submitHandler: SubmitHandler? = nil) {
        self.submitHandler = submitHandler
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "添加邮箱验证码账号"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 620, height: 640)
        panel.center()
        panel.delegate = self
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        buildContent()
    }

    func runModal() -> EmailAccountDraft? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        isRunningModally = true
        NSApp.runModal(for: panel)
        isRunningModally = false
        return submittedDraft
    }

    func windowWillClose(_ notification: Notification) {
        submittedDraft = nil
        stopModalIfNeeded()
    }

    @objc private func save() {
        do {
            let draft = try form.makeDraft()
            guard let submitHandler else {
                submittedDraft = draft
                closeModal()
                return
            }
            setSaving(true)
            setValidationMessage("正在测试连接并保存…", color: .secondaryLabelColor, copyable: false)
            submitHandler(draft) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.submittedDraft = draft
                    self.closeModal()
                case let .failure(message):
                    self.submittedDraft = nil
                    self.setValidationMessage(message, color: .systemRed, copyable: true)
                    self.setSaving(false)
                }
            }
        } catch {
            setValidationMessage(error.localizedDescription, color: .systemRed, copyable: true)
        }
    }

    @objc private func cancel() {
        submittedDraft = nil
        closeModal()
    }

    @objc private func copyDiagnostic() {
        let text = validationLabel.stringValue
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func closeModal() {
        panel.orderOut(nil)
        stopModalIfNeeded()
    }

    private func setSaving(_ isSaving: Bool) {
        form.concealPasswordForTesting()
        saveButton.isEnabled = !isSaving
        cancelButton.isEnabled = !isSaving
        saveButton.title = isSaving ? "正在保存…" : "测试并保存"
    }

    private func setValidationMessage(
        _ message: String,
        color: NSColor,
        copyable: Bool
    ) {
        validationLabel.textColor = color
        validationLabel.stringValue = message
        copyDiagnosticButton.isHidden = !copyable || message.isEmpty
    }

    private func stopModalIfNeeded() {
        guard isRunningModally else { return }
        NSApp.stopModal()
    }

    private func buildContent() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let title = NSTextField(labelWithString: "添加邮箱验证码账号")
        title.font = .boldSystemFont(ofSize: 18)
        let subtitle = NSTextField(
            wrappingLabelWithString: "请使用应用专用密码或授权码，不要填写邮箱主密码。保存前会先进行只读 IMAP 连接测试；连接失败时密码只保留在当前窗口内存中。"
        )
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2

        validationLabel.textColor = .systemRed
        validationLabel.identifier = NSUserInterfaceItemIdentifier("email-account-validation")
        validationLabel.font = .systemFont(ofSize: 12)
        validationLabel.maximumNumberOfLines = 0
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.isSelectable = true
        validationLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)

        copyDiagnosticButton.target = self
        copyDiagnosticButton.action = #selector(copyDiagnostic)
        copyDiagnosticButton.identifier = NSUserInterfaceItemIdentifier("email-account-copy-diagnostic")
        copyDiagnosticButton.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.identifier = NSUserInterfaceItemIdentifier("email-account-cancel")
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.identifier = NSUserInterfaceItemIdentifier("email-account-save")
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor
        form.configureTabOrder(endingWith: cancelButton)
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = form
        let spacer = NSView()
        let buttons = NSStackView(views: [copyDiagnosticButton, spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [title, subtitle, form, validationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            form.widthAnchor.constraint(equalToConstant: 556),
            subtitle.widthAnchor.constraint(equalToConstant: 556),
            validationLabel.widthAnchor.constraint(equalToConstant: 556),
            buttons.widthAnchor.constraint(equalToConstant: 556),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1)
        ])
    }
}
