import Foundation
import Network
import SmsCodeCore

enum EmailConnectionErrorPresenter {
    static func message(for error: Error) -> String {
        if let authenticationFailure = error as? IMAPAuthenticationFailure {
            return authenticationFailure.errorDescription ?? "88 邮箱连接失败"
        }
        return "邮箱连接失败\n分类：\(classification(for: error))"
    }

    static func classification(for error: Error) -> String {
        if let networkError = error as? NWError {
            return classify(networkError)
        }
        if let imapError = error as? NetworkIMAPError {
            return classify(imapError)
        }
        if let protocolError = error as? IMAPProtocolError {
            return classify(protocolError)
        }

        let sanitized = EmailLogSanitizer.sanitizeError(error.localizedDescription)
        if sanitized.isEmpty || sanitized.contains(" error 0") || sanitized.contains("SmsCodeCore.") {
            return "协议响应异常：服务器返回了无法识别的 IMAP 响应，请检查服务商配置和 IMAP 服务状态。"
        }
        return "协议响应异常：\(sanitized)"
    }

    private static func classify(_ error: NetworkIMAPError) -> String {
        switch error {
        case .invalidConfiguration:
            return "DNS/网络连接失败：IMAP 主机或端口无效，请检查主机名和端口。"
        case .tlsRequired:
            return "TLS 握手或证书失败：当前账号必须启用 TLS，建议使用 993 端口。"
        case .connectionClosed:
            return "DNS/网络连接失败：IMAP 服务器关闭了连接，请检查网络、主机、端口和服务是否开启。"
        case .invalidGreeting:
            return "协议响应异常：服务器欢迎响应不是有效 IMAP 响应，请确认主机是 IMAP 服务。"
        case .oversizedResponse:
            return "协议响应异常：服务器响应超过安全上限。"
        }
    }

    private static func classify(_ error: IMAPProtocolError) -> String {
        switch error {
        case .commandFailed("NO"):
            return "登录/授权码被拒绝：请检查邮箱地址、IMAP 用户名、授权码或专用密码，并确认 IMAP 服务已开启。"
        case .commandFailed("BAD"):
            return "IMAP 服务端拒绝：服务器拒绝了命令，请检查服务商、主机、端口和账号配置。"
        case let .commandFailed(status):
            let safeStatus = EmailLogSanitizer.sanitizeError(status)
            return "IMAP 服务端拒绝：服务器返回 \(safeStatus)，请检查服务商配置。"
        case .malformedResponse, .missingUIDValidity, .missingLiteral, .responseTooLarge:
            return "协议响应异常：服务器返回了无法识别的 IMAP 响应，请检查服务商配置和 IMAP 服务状态。"
        }
    }

    private static func classify(_ error: NWError) -> String {
        switch error {
        case .dns:
            return "DNS/网络连接失败：无法解析 IMAP 主机，请检查主机名和网络。"
        case .tls:
            return "TLS 握手或证书失败：请确认 TLS 已开启、端口为 993，且主机证书有效。"
        case let .posix(code):
            return "DNS/网络连接失败：无法连接 IMAP 服务（\(posixHint(code))）。"
        @unknown default:
            return "DNS/网络连接失败：无法建立 IMAP 连接，请检查网络、主机和端口。"
        }
    }

    private static func posixHint(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ECONNREFUSED:
            return "连接被拒绝，请检查主机和端口"
        case .ETIMEDOUT:
            return "连接超时，请检查网络或服务是否可达"
        case .ENETUNREACH, .EHOSTUNREACH:
            return "网络或主机不可达"
        default:
            return "系统网络错误 \(code.rawValue)"
        }
    }
}
