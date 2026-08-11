import CoreFoundation
import Foundation

public struct ParsedEmailContent: Equatable {
    public let subject: String
    public let body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}

public enum EmailMIMEParserError: Error, Equatable {
    case malformedMessage
    case unsupportedCharset(String)
}

public struct EmailMIMEParser {
    private static let maxDecodedTextCharacters = 24_000

    public init() {}

    public func parse(_ data: Data) throws -> ParsedEmailContent {
        let root = try splitHeadersAndBody(data)
        let headers = parseHeaders(root.headers)
        let subject = decodeHeaderValue(headers["subject"] ?? "")
        let bodies = try textBodies(headers: headers, body: root.body)
        return ParsedEmailContent(
            subject: subject,
            body: bodies.filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    private func textBodies(headers: [String: String], body: Data) throws -> [String] {
        let contentType = headers["content-type"] ?? "text/plain; charset=utf-8"
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "text/plain"

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = parameter(named: "boundary", in: contentType), !boundary.isEmpty else {
                throw EmailMIMEParserError.malformedMessage
            }
            return try multipartSections(body, boundary: boundary).flatMap { section in
                let part = try splitHeadersAndBody(section)
                return try textBodies(headers: parseHeaders(part.headers), body: part.body)
            }
        }

        guard mediaType == "text/plain" || mediaType == "text/html" else {
            return []
        }

        let decodedData = decodeTransferEncoding(
            body,
            encoding: headers["content-transfer-encoding"]?.lowercased()
        )
        let charset = parameter(named: "charset", in: contentType) ?? "utf-8"
        let decoded = try decodeText(decodedData, charset: charset)
        let text = mediaType == "text/html" ? plainText(fromHTML: decoded) : decoded
        return [String(text.prefix(Self.maxDecodedTextCharacters))]
    }

    private func splitHeadersAndBody(_ data: Data) throws -> (headers: Data, body: Data) {
        let separators = [Data("\r\n\r\n".utf8), Data("\n\n".utf8)]
        for separator in separators {
            if let range = data.range(of: separator) {
                return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
            }
        }
        throw EmailMIMEParserError.malformedMessage
    }

    private func parseHeaders(_ data: Data) -> [String: String] {
        let raw = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let unfolded = raw.replacingOccurrences(
            of: #"\r?\n[\t ]+"#,
            with: " ",
            options: .regularExpression
        )
        var result: [String: String] = [:]
        for line in unfolded.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                result[name] = result[name].map { "\($0), \(value)" } ?? value
            }
        }
        return result
    }

    private func parameter(named name: String, in header: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "(?:^|;)\\s*\(escaped)\\s*=\\s*(?:\"([^\"]+)\"|([^;\\s]+))",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsHeader = header as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: header, range: range) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return nsHeader.substring(with: match.range(at: index))
        }
        return nil
    }

    private func multipartSections(_ data: Data, boundary: String) -> [Data] {
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        let marker = "--\(boundary)"
        return raw.components(separatedBy: marker).compactMap { component in
            var value = component
            if value.hasPrefix("--") { return nil }
            value = value.trimmingCharacters(in: .newlines)
            guard !value.isEmpty else { return nil }
            return value.data(using: .isoLatin1)
        }
    }

    private func decodeTransferEncoding(_ data: Data, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "base64":
            let compact = data.filter { byte in
                ![9, 10, 13, 32].contains(byte)
            }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    private func decodeQuotedPrintable(_ data: Data, underscoreAsSpace: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if underscoreAsSpace, bytes[index] == 95 {
                result.append(32)
                index += 1
                continue
            }
            if bytes[index] == 61 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2]) {
                    result.append(high * 16 + low)
                    index += 3
                    continue
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return Data(result)
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private func decodeText(_ data: Data, charset: String) throws -> String {
        let normalized = charset
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .lowercased()
        let aliases: [String: String] = [
            "gb2312": "GB18030",
            "gbk": "GB18030",
            "gb18030": "GB18030",
            "gb_18030-2000": "GB18030"
        ]
        let ianaName = aliases[normalized] ?? charset
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
            throw EmailMIMEParserError.unsupportedCharset(charset)
        }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        if let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeHeaderValue(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        ) else { return value }
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }

        var output = value
        for match in matches.reversed() {
            let charset = nsValue.substring(with: match.range(at: 1))
            let mode = nsValue.substring(with: match.range(at: 2)).lowercased()
            let payload = nsValue.substring(with: match.range(at: 3))
            let encodedData = payload.data(using: .isoLatin1) ?? Data()
            let bytes = mode == "b"
                ? (Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? encodedData)
                : decodeQuotedPrintable(encodedData, underscoreAsSpace: true)
            let replacement = (try? decodeText(bytes, charset: charset)) ?? ""
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }

    private func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<[^>]*(?:hidden|aria-hidden\s*=\s*["']?true|display\s*:\s*none|visibility\s*:\s*hidden)[^>]*>.*?</[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
    }
}
