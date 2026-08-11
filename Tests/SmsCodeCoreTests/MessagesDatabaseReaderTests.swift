import CSQLite
import Foundation
import ObjectiveC
import Testing
@testable import SmsCodeCore

struct MessagesDatabaseReaderTests {
    @Test func readsLatestMessagesFromSampleDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("chat.db")
        defer { try? FileManager.default.removeItem(at: directory) }

        try createSampleDatabase(at: databaseURL)

        let reader = MessagesDatabaseReader(databaseURL: databaseURL)
        let messages = try reader.latestMessages(limit: 10)

        #expect(messages.map(\.text) == ["验证码222222", "验证码111111"])
        #expect(messages.first?.service == "SMS")
    }

    private func createSampleDatabase(at url: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        let sql = """
        CREATE TABLE message (
            text TEXT,
            attributedBody BLOB,
            date INTEGER,
            service TEXT,
            is_from_me INTEGER
        );
        INSERT INTO message VALUES ('验证码111111', NULL, 1000000000, 'SMS', 0);
        INSERT INTO message VALUES ('验证码222222', NULL, 2000000000, 'SMS', 0);
        INSERT INTO message VALUES ('自己发出的验证码333333', NULL, 3000000000, 'SMS', 1);
        INSERT INTO message VALUES ('邮箱验证码444444', NULL, 4000000000, 'Email', 0);
        """

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知 SQLite 错误"
            sqlite3_free(error)
            throw TestFailure(message)
        }
    }

    @Test func decodesAttributedBody() {
        let archived = LegacyTypedStreamArchive.archive(NSAttributedString(string: "验证码333333"))

        #expect(MessagesDatabaseReader.decodedAttributedBody(archived) == "验证码333333")
    }
}

private enum LegacyTypedStreamArchive {
    static func archive(_ object: Any) -> Data {
        guard let archiver = NSClassFromString("NSArchiver") else {
            return Data()
        }
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        guard let method = class_getClassMethod(archiver, selector) else {
            return Data()
        }

        typealias ArchiveFunction = @convention(c) (AnyClass, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: ArchiveFunction.self)
        return function(archiver, selector, object as AnyObject)?.takeUnretainedValue() as? Data ?? Data()
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
