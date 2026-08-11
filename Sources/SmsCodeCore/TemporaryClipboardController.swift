import Foundation

public protocol ClipboardStoring: AnyObject {
    func write(_ text: String)
    func read() -> String?
    func clear()
}

public final class TemporaryClipboardController {
    private let store: ClipboardStoring
    private let lifetime: TimeInterval
    private let queue = DispatchQueue(label: "local.sms-code-menubar.temporary-clipboard")
    private var clearWorkItem: DispatchWorkItem?

    public init(store: ClipboardStoring, lifetime: TimeInterval = 60) {
        self.store = store
        self.lifetime = lifetime
    }

    deinit {
        clearWorkItem?.cancel()
    }

    @discardableResult
    public func copyTemporary(_ text: String, attempts: Int = 3) -> Bool {
        clearWorkItem?.cancel()

        let didCopy = (0..<max(1, attempts)).contains { _ in
            store.clear()
            store.write(text)
            return store.read() == text
        }

        guard didCopy else {
            return false
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.store.read() == text {
                self.store.clear()
            }
        }
        clearWorkItem = workItem
        queue.asyncAfter(deadline: .now() + lifetime, execute: workItem)
        return true
    }

    public func currentText() -> String? {
        store.read()
    }
}
