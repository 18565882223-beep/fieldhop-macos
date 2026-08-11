import AppKit

@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let contentController: StatusPopoverViewController
    private let panel: NSPanel
    private static let menuBarIconSize = NSSize(width: 18, height: 18)

    init(coordinator: AppCoordinator) {
        self.contentController = StatusPopoverViewController(coordinator: coordinator)
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        configureStatusItem()
        configurePanel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        if let image = loadMenuBarIcon() {
            statusItem.length = NSStatusItem.squareLength
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.title = "短信"
        }
        button.toolTip = "短信验证码自动输入"
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func loadMenuBarIcon() -> NSImage? {
        let projectIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("图标")
            .appendingPathComponent("menubar.png")
        let candidateURLs = [
            Bundle.main.url(forResource: "menubar", withExtension: "png"),
            projectIconURL
        ].compactMap { $0 }

        for url in candidateURLs {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            image.size = Self.menuBarIconSize
            return image
        }

        return nil
    }

    private func configurePanel() {
        panel.title = "短信验证码"
        panel.contentViewController = contentController
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = true
        // 菜单栏在全屏 Space 中属于独立层级，面板必须声明可进入全屏辅助层。
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.animationBehavior = .utilityWindow
    }

    func showPanel() {
        contentController.refresh()
        if let button = statusItem.button {
            positionPanel(relativeTo: button)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            panel.orderOut(sender)
        } else {
            contentController.refresh()
            positionPanel(relativeTo: sender)
            panel.makeKeyAndOrderFront(sender)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func positionPanel(relativeTo sender: NSStatusBarButton) {
        guard let window = sender.window,
              let screen = window.screen else {
            panel.center()
            return
        }

        let buttonFrameInWindow = sender.convert(sender.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame
        let x = min(
            max(buttonFrameOnScreen.midX - panelSize.width / 2, visibleFrame.minX + 12),
            visibleFrame.maxX - panelSize.width - 12
        )
        let y = min(
            buttonFrameOnScreen.minY - panelSize.height - 8,
            visibleFrame.maxY - panelSize.height - 12
        )
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, visibleFrame.minY + 12)))
    }
}
