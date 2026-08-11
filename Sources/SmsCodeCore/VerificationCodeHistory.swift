import Foundation

public struct VerificationCodeHistoryItem: Equatable, Identifiable {
    public let id: UUID
    public let code: String
    public let date: Date
    public let source: String?

    public init(id: UUID = UUID(), code: String, date: Date, source: String? = nil) {
        self.id = id
        self.code = code
        self.date = date
        self.source = source
    }

    public var maskedCode: String {
        CodeMasker.masked(code)
    }
}

public struct VerificationCodeHistory: Equatable {
    public private(set) var items: [VerificationCodeHistoryItem]
    private let maxCount: Int

    public init(maxCount: Int = 5, items: [VerificationCodeHistoryItem] = []) {
        self.maxCount = max(1, maxCount)
        self.items = Array(items.prefix(max(1, maxCount)))
    }

    public mutating func record(code: String, date: Date = Date(), source: String? = nil) {
        items.removeAll { $0.code == code }
        items.insert(VerificationCodeHistoryItem(code: code, date: date, source: source), at: 0)
        if items.count > maxCount {
            items.removeLast(items.count - maxCount)
        }
    }

    public func code(at index: Int) -> String? {
        guard items.indices.contains(index) else { return nil }
        return items[index].code
    }
}
