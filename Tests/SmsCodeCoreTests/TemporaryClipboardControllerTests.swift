import Foundation
import Testing
@testable import SmsCodeCore

struct TemporaryClipboardControllerTests {
    @Test func clearsOnlyUnchangedCodeAfterLifetime() async throws {
        let store = MemoryClipboardStore()
        let controller = TemporaryClipboardController(store: store, lifetime: 0.2)

        controller.copyTemporary("654321")
        #expect(store.read() == "654321")

        try await Task.sleep(for: .milliseconds(260))
        #expect(store.read() == nil)
    }

    @Test func doesNotClearUserReplacedClipboardValue() async throws {
        let store = MemoryClipboardStore()
        let controller = TemporaryClipboardController(store: store, lifetime: 0.2)

        controller.copyTemporary("654321")
        store.write("用户自己的剪贴板内容")

        try await Task.sleep(for: .milliseconds(260))
        #expect(store.read() == "用户自己的剪贴板内容")
    }

    @Test func retriesUntilClipboardContainsLatestCode() {
        let store = FlakyClipboardStore(failedWritesBeforeSuccess: 1)
        let controller = TemporaryClipboardController(store: store, lifetime: 60)

        let copied = controller.copyTemporary("888999", attempts: 3)

        #expect(copied)
        #expect(store.read() == "888999")
        #expect(store.writeAttempts == 2)
    }
}

private final class MemoryClipboardStore: ClipboardStoring {
    private let lock = NSLock()
    private var value: String?

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        value = text
    }

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}

private final class FlakyClipboardStore: ClipboardStoring {
    private let failedWritesBeforeSuccess: Int
    private var value: String?
    private(set) var writeAttempts = 0

    init(failedWritesBeforeSuccess: Int) {
        self.failedWritesBeforeSuccess = failedWritesBeforeSuccess
    }

    func write(_ text: String) {
        writeAttempts += 1
        if writeAttempts > failedWritesBeforeSuccess {
            value = text
        }
    }

    func read() -> String? {
        value
    }

    func clear() {
        value = nil
    }
}
