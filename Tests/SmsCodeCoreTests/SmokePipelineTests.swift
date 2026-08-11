import CoreServices
import CSQLite
import Foundation
import Testing
@testable import SmsCodeCore

struct SmokePipelineTests {
    @Test func fakeDatabaseChangeTriggersTypingPath() throws {
        let action = try runFakeDatabaseSmoke(
            focusedElement: FocusedElementSnapshot(
                role: "AXTextField",
                placeholder: "验证码",
                value: "",
                width: 120
            )
        )

        #expect(action == .type("246810"))
    }

    @Test func fakeDatabaseChangeTriggersClipboardFallbackPath() throws {
        let action = try runFakeDatabaseSmoke(
            focusedElement: FocusedElementSnapshot(
                role: "AXSearchField",
                placeholder: "搜索",
                value: "",
                width: 420
            )
        )

        #expect(action == .clipboard("246810"))
    }

    private func runFakeDatabaseSmoke(focusedElement: FocusedElementSnapshot) throws -> SmokeAction {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("chat.db")
        try createEmptyDatabase(at: databaseURL)

        let reader = MessagesDatabaseReader(databaseURL: databaseURL)
        let selector = VerificationCodeSelector()
        let classifier = FocusedElementClassifier()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedAction: SmokeAction?

        let watcher = try TestDatabaseWatcher(watchedURL: directory) {
            guard let detected = try? selector.latestCode(in: reader.latestMessages(limit: 5)) else {
                return
            }

            let action: SmokeAction = classifier.isStrongVerificationField(focusedElement)
                ? .type(detected.code)
                : .clipboard(detected.code)

            lock.lock()
            if capturedAction == nil {
                capturedAction = action
                semaphore.signal()
            }
            lock.unlock()
        }
        defer { watcher.stop() }

        try insertMessage("【冒烟测试】验证码246810，5分钟内有效。", into: databaseURL)

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw SmokeFailure("造假短信库变化没有触发监听链路")
        }

        lock.lock()
        let action = capturedAction
        lock.unlock()

        guard let action else {
            throw SmokeFailure("监听触发后没有产出处理动作")
        }
        return action
    }

    private func createEmptyDatabase(at url: URL) throws {
        let sql = """
        CREATE TABLE message (
            text TEXT,
            attributedBody BLOB,
            date INTEGER,
            service TEXT,
            is_from_me INTEGER
        );
        """
        try execute(sql, databaseURL: url)
    }

    private func insertMessage(_ text: String, into url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw SmokeFailure("打开测试数据库失败")
        }
        defer { sqlite3_close(database) }

        let sql = """
        INSERT INTO message (text, attributedBody, date, service, is_from_me)
        VALUES (?, NULL, ?, 'SMS', 0);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SmokeFailure("准备插入测试短信失败")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 2, appleMessagesTimestamp(Date()))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SmokeFailure("插入测试短信失败")
        }
    }

    private func execute(_ sql: String, databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw SmokeFailure("打开测试数据库失败")
        }
        defer { sqlite3_close(database) }

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知 SQLite 错误"
            sqlite3_free(error)
            throw SmokeFailure(message)
        }
    }

    private func appleMessagesTimestamp(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }
}

private enum SmokeAction: Equatable {
    case type(String)
    case clipboard(String)
}

private final class TestDatabaseWatcher {
    private let queue = DispatchQueue(label: "local.sms-code-menubar.tests.database-watcher")
    private var stream: FSEventStreamRef?

    init(watchedURL: URL, onChange: @escaping () -> Void) throws {
        final class CallbackBox {
            let onChange: () -> Void

            init(onChange: @escaping () -> Void) {
                self.onChange = onChange
            }
        }

        let box = CallbackBox(onChange: onChange)
        let boxPointer = Unmanaged.passRetained(box).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: boxPointer,
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<CallbackBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watchedURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream else {
            Unmanaged<CallbackBox>.fromOpaque(boxPointer).release()
            throw SmokeFailure("创建 FSEvents 监听失败")
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
