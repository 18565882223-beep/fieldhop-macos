import CSQLite
import Foundation
import ObjectiveC

public enum MessagesDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "打开短信数据库失败：\(message)"
        case let .prepareFailed(message):
            return "准备短信查询失败：\(message)"
        case let .stepFailed(message):
            return "读取短信数据库失败：\(message)"
        }
    }
}

public final class MessagesDatabaseReader {
    private let databaseURL: URL

    public init(databaseURL: URL = MessagesDatabaseReader.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    public static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    public func latestMessages(limit: Int = 20) throws -> [SMSMessage] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(database)
            throw MessagesDatabaseError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT text, attributedBody, date, service
        FROM message
        WHERE is_from_me = 0
          AND ((text IS NOT NULL AND length(text) > 0) OR attributedBody IS NOT NULL)
          AND (service IS NULL OR service IN ('SMS', 'iMessage'))
        ORDER BY date DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessagesDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var messages: [SMSMessage] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                guard let text = Self.messageText(from: statement) else {
                    continue
                }
                let rawDate = sqlite3_column_int64(statement, 2)
                let service = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                messages.append(
                    SMSMessage(
                        text: text,
                        date: Self.dateFromAppleMessagesTimestamp(rawDate),
                        service: service
                    )
                )
            } else if result == SQLITE_DONE {
                break
            } else {
                throw MessagesDatabaseError.stepFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        return messages
    }

    static func messageText(from statement: OpaquePointer?) -> String? {
        if let textPointer = sqlite3_column_text(statement, 0) {
            let text = String(cString: textPointer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        guard let blobPointer = sqlite3_column_blob(statement, 1) else {
            return nil
        }

        let length = Int(sqlite3_column_bytes(statement, 1))
        guard length > 0 else { return nil }

        let data = Data(bytes: blobPointer, count: length)
        return decodedAttributedBody(data)
    }

    public static func decodedAttributedBody(_ data: Data) -> String? {
        // Messages 的 attributedBody 是旧 typedstream 格式，真实环境仍需 NSUnarchiver 读取。
        if let attributedString = LegacyTypedStreamArchive.unarchive(data) as? NSAttributedString {
            let text = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty {
            return text
        }

        return nil
    }

    public static func dateFromAppleMessagesTimestamp(_ rawValue: Int64) -> Date {
        let appleEpoch = Date(timeIntervalSinceReferenceDate: 0)
        let absolute = abs(rawValue)

        if absolute > 10_000_000_000_000 {
            return appleEpoch.addingTimeInterval(TimeInterval(rawValue) / 1_000_000_000)
        }

        if absolute > 10_000_000_000 {
            return appleEpoch.addingTimeInterval(TimeInterval(rawValue) / 1_000_000)
        }

        return appleEpoch.addingTimeInterval(TimeInterval(rawValue))
    }
}

private enum LegacyTypedStreamArchive {
    static func unarchive(_ data: Data) -> Any? {
        guard let unarchiver = NSClassFromString("NSUnarchiver") else {
            return nil
        }
        let selector = NSSelectorFromString("unarchiveObjectWithData:")
        guard let method = class_getClassMethod(unarchiver, selector) else {
            return nil
        }

        typealias UnarchiveFunction = @convention(c) (AnyClass, Selector, NSData) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: UnarchiveFunction.self)
        return function(unarchiver, selector, data as NSData)?.takeUnretainedValue()
    }
}
