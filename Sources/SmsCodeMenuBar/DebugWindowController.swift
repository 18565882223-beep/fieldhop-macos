import AppKit

@MainActor
final class DebugWindowController: NSWindowController {
    private let coordinator: AppCoordinator
    private let stateLabel = NSTextField(labelWithString: "")
    private let recentCodeLabel = NSTextField(labelWithString: "")
    private let permissionLabel = NSTextField(labelWithString: "")
    private let autoClickLabel = NSTextField(labelWithString: "")

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "短信验证码调试"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.contentView = buildContentView()

        coordinator.addStateObserver { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContentView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "短信验证码调试")
        title.font = .boldSystemFont(ofSize: 18)

        [stateLabel, recentCodeLabel, permissionLabel].forEach {
            $0.font = .systemFont(ofSize: 13)
            $0.lineBreakMode = .byWordWrapping
            $0.maximumNumberOfLines = 2
        }

        let stack = NSStackView(views: [
            title,
            stateLabel,
            recentCodeLabel,
            permissionLabel,
            autoClickLabel,
            button("3秒后导出焦点诊断", action: #selector(exportDiagnostics)),
            button("测试粘贴 123456", action: #selector(testPaste)),
            button("强制填入最近验证码", action: #selector(forceFill)),
            button("切换自动点击登录", action: #selector(toggleAutoClick)),
            button("设置默认手机号", action: #selector(setDefaultPhone)),
            button("用默认手机号获取验证码", action: #selector(startDefaultPhoneLogin)),
            button("打开辅助功能授权", action: #selector(openAccessibility)),
            button("打开完全磁盘访问设置", action: #selector(openFullDiskAccess)),
            button("退出工具", action: #selector(quit))
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22)
        ])

        return root
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    private func refresh() {
        stateLabel.stringValue = "状态：\(coordinator.recentAction)"
        recentCodeLabel.stringValue = "最近验证码：\(coordinator.maskedRecentCode)"
        permissionLabel.stringValue = "辅助功能：\(coordinator.hasAccessibilityPermission ? "已授权" : "未授权")"
        autoClickLabel.stringValue = "自动点击登录：\(coordinator.autoClickModeTitle)"
    }

    @objc private func exportDiagnostics() {
        coordinator.exportFocusDiagnostics()
        refresh()
    }

    @objc private func testPaste() {
        coordinator.testPasteCode()
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

    @objc private func setDefaultPhone() {
        coordinator.promptAndSaveDefaultPhoneNumber()
        refresh()
    }

    @objc private func startDefaultPhoneLogin() {
        coordinator.startLoginWithDefaultPhoneNumber()
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
