import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let coordinator = AppCoordinator()
        self.coordinator = coordinator

        self.menuBarController = MenuBarController(coordinator: coordinator)

        coordinator.start()

        if ProcessInfo.processInfo.environment["SMS_CODE_EMAIL_FORM_UI_TEST"] == "1" {
            DispatchQueue.main.async {
                coordinator.promptAndAddEmailAccount()
            }
        }

        // 激活一次 App 让菜单栏刷新并显示 statusItem；对 accessory app 无 Dock 副作用。
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SmsCodeMenuBarApp {
    // 必须用 strong 引用持有 AppDelegate，否则 app.delegate (weak) 会让它被释放，
    // 导致 menuBarController 和 statusItem 一起被销毁，菜单栏图标消失。
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
