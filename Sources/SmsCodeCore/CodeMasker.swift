import Foundation

public enum CodeMasker {
    public static func masked(_ code: String) -> String {
        guard code.count > 2 else { return String(repeating: "*", count: code.count) }
        let suffix = code.suffix(2)
        return String(repeating: "*", count: max(0, code.count - 2)) + suffix
    }
}
