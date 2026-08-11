import Foundation
import Network
import SmsCodeCore

enum NetworkIMAPError: Error, LocalizedError {
    case invalidConfiguration
    case tlsRequired
    case connectionClosed
    case invalidGreeting
    case oversizedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "IMAP 主机或端口无效"
        case .tlsRequired: return "邮箱监听必须启用 TLS"
        case .connectionClosed: return "IMAP 连接已关闭"
        case .invalidGreeting: return "IMAP 服务器欢迎响应无效"
        case .oversizedResponse: return "邮件响应超过 2 MB 安全上限"
        }
    }
}

final class NetworkIMAPMailboxClient: IMAPMailboxClient {
    private let account: EmailAccount
    private let queue: DispatchQueue
    private let parser = EmailMIMEParser()
    private var connection: NWConnection?
    private var tagCounter = 0
    private let maximumResponseBytes = 2 * 1_024 * 1_024
    private(set) var authenticationDiagnostic: IMAPAuthenticationDiagnostic?

    init(account: EmailAccount) {
        self.account = account
        self.queue = DispatchQueue(label: "local.sms-code-menubar.imap.\(account.id.uuidString)")
    }

    func connect(username: String, password: String, requiresClientID: Bool) async throws {
        guard !account.host.isEmpty,
              account.port > 0,
              account.port <= 65_535,
              let port = NWEndpoint.Port(rawValue: UInt16(account.port)) else {
            throw NetworkIMAPError.invalidConfiguration
        }
        guard account.useTLS else { throw NetworkIMAPError.tlsRequired }

        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions)
        let connection = NWConnection(host: NWEndpoint.Host(account.host), port: port, using: parameters)
        self.connection = connection
        connection.start(queue: queue)

        do {
            let greeting = try await receiveGreeting()
            guard greeting.uppercased().contains("* OK") else {
                throw NetworkIMAPError.invalidGreeting
            }

            if account.isPerfect88IMAP {
                try await authenticatePerfect88(username: username, password: password)
            } else {
                let loginTag = nextTag()
                let loginResponse = try await sendAndReceive(
                    IMAPCommandBuilder.login(tag: loginTag, username: username, password: password),
                    tag: loginTag
                )
                try IMAPResponseParser.requireOK(tag: loginTag, in: loginResponse)
            }

            if requiresClientID {
                let idTag = nextTag()
                let idResponse = try await sendAndReceive(IMAPCommandBuilder.clientID(tag: idTag), tag: idTag)
                try IMAPResponseParser.requireOK(tag: idTag, in: idResponse)
            }
        } catch {
            connection.cancel()
            self.connection = nil
            if account.isPerfect88IMAP, !(error is IMAPAuthenticationFailure) {
                let currentDiagnostic = authenticationDiagnostic
                let diagnostic = IMAPAuthenticationDiagnostic(
                    endpoint: authenticationEndpoint,
                    capabilities: currentDiagnostic?.capabilities ?? .unavailable,
                    attempts: currentDiagnostic?.attempts ?? [],
                    conclusion: authenticationConclusion(for: error)
                )
                authenticationDiagnostic = diagnostic
                throw IMAPAuthenticationFailure(diagnostic: diagnostic)
            }
            throw error
        }
    }

    func mailboxState() async throws -> IMAPMailboxState {
        let examineTag = nextTag()
        let examineResponse = try await sendAndReceive(
            IMAPCommandBuilder.examineInbox(tag: examineTag),
            tag: examineTag
        )
        try IMAPResponseParser.requireOK(tag: examineTag, in: examineResponse)
        let uidValidity = try IMAPResponseParser.uidValidity(in: examineResponse)

        let searchTag = nextTag()
        let searchResponse = try await sendAndReceive(IMAPCommandBuilder.searchAll(tag: searchTag), tag: searchTag)
        try IMAPResponseParser.requireOK(tag: searchTag, in: searchResponse)
        return IMAPMailboxState(
            uidValidity: uidValidity,
            maximumUID: IMAPResponseParser.searchUIDs(in: searchResponse).max() ?? 0
        )
    }

    func fetchMessages(afterUID: UInt64) async throws -> EmailMessageFetchBatch {
        let searchTag = nextTag()
        let searchResponse = try await sendAndReceive(
            IMAPCommandBuilder.search(afterUID: afterUID, tag: searchTag),
            tag: searchTag
        )
        try IMAPResponseParser.requireOK(tag: searchTag, in: searchResponse)
        let newUIDs = IMAPResponseParser.searchUIDs(in: searchResponse)
            .filter { $0 > afterUID }
            .sorted()
            .suffix(50)

        var messages: [EmailVerificationMessage] = []
        var diagnostics: [EmailMessageFetchDiagnostic] = []
        for uid in newUIDs {
            try Task.checkCancellation()
            let fetchTag = nextTag()
            let response: Data
            do {
                response = try await sendAndReceive(IMAPCommandBuilder.fetch(uid: uid, tag: fetchTag), tag: fetchTag)
                try IMAPResponseParser.requireOK(tag: fetchTag, in: response)
            } catch {
                diagnostics.append(
                    EmailMessageFetchDiagnostic(
                        uid: uid,
                        fetchSucceeded: false,
                        mimeSucceeded: false,
                        sanitizedError: EmailLogSanitizer.sanitizeError(error.localizedDescription)
                    )
                )
                continue
            }

            let date = IMAPResponseParser.internalDate(in: response) ?? Date()
            do {
                let rawMessage = try IMAPResponseParser.literal(in: response)
                let content = try parser.parse(rawMessage)
                messages.append(
                    EmailVerificationMessage(
                        accountID: account.id,
                        uid: uid,
                        date: date,
                        subject: content.subject,
                        body: content.body
                    )
                )
                diagnostics.append(
                    EmailMessageFetchDiagnostic(uid: uid, fetchSucceeded: true, mimeSucceeded: true)
                )
            } catch {
                diagnostics.append(
                    EmailMessageFetchDiagnostic(
                        uid: uid,
                        fetchSucceeded: true,
                        mimeSucceeded: false,
                        sanitizedError: EmailLogSanitizer.sanitizeError(error.localizedDescription)
                    )
                )
            }
        }
        return EmailMessageFetchBatch(
            discoveredUIDs: Array(newUIDs),
            messages: messages,
            diagnostics: diagnostics
        )
    }

    func disconnect() async {
        guard let connection else { return }
        if !Task.isCancelled {
            let tag = nextTag()
            _ = try? await sendAndReceive(IMAPCommandBuilder.logout(tag: tag), tag: tag)
        }
        connection.cancel()
        self.connection = nil
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    private func authenticatePerfect88(username: String, password: String) async throws {
        let capabilityTag = nextTag()
        let capabilityResponse = try await sendAndReceive(
            IMAPCommandBuilder.capability(tag: capabilityTag),
            tag: capabilityTag
        )
        try IMAPResponseParser.requireOK(tag: capabilityTag, in: capabilityResponse)
        let capabilities = IMAPResponseParser.capabilitySummary(in: capabilityResponse)
        authenticationDiagnostic = IMAPAuthenticationDiagnostic(
            endpoint: authenticationEndpoint,
            capabilities: capabilities,
            attempts: [],
            conclusion: .protocolFailure
        )
        guard capabilities.wasRetrieved else {
            let diagnostic = IMAPAuthenticationDiagnostic(
                endpoint: authenticationEndpoint,
                capabilities: capabilities,
                attempts: [],
                conclusion: .capabilityUnavailable
            )
            authenticationDiagnostic = diagnostic
            throw IMAPAuthenticationFailure(diagnostic: diagnostic)
        }
        guard let primary = IMAPAuthenticationPlanner.primaryAttempt(capabilities: capabilities) else {
            let diagnostic = IMAPAuthenticationDiagnostic(
                endpoint: authenticationEndpoint,
                capabilities: capabilities,
                attempts: [],
                conclusion: .authenticationUnsupported
            )
            authenticationDiagnostic = diagnostic
            throw IMAPAuthenticationFailure(diagnostic: diagnostic)
        }

        let isFullAddress = username.caseInsensitiveCompare(account.emailAddress) == .orderedSame
        var attempts: [IMAPAuthenticationAttempt] = []
        let firstAttempt = try await authenticate(
            username: username,
            password: password,
            usernameMode: primary.usernameMode,
            method: primary.method
        )
        attempts.append(firstAttempt)
        authenticationDiagnostic = IMAPAuthenticationDiagnostic(
            endpoint: authenticationEndpoint,
            capabilities: capabilities,
            attempts: attempts,
            conclusion: .protocolFailure
        )
        if firstAttempt.completion == .ok {
            authenticationDiagnostic = IMAPAuthenticationDiagnostic(
                endpoint: authenticationEndpoint,
                capabilities: capabilities,
                attempts: attempts,
                conclusion: .connected
            )
            return
        }

        if let fallback = IMAPAuthenticationPlanner.fallbackAttempt(
            after: firstAttempt,
            usernameIsFullAddress: isFullAddress
        ), let localPart = username.split(separator: "@", maxSplits: 1).first, !localPart.isEmpty {
            let fallbackAttempt = try await authenticate(
                username: String(localPart),
                password: password,
                usernameMode: fallback.usernameMode,
                method: fallback.method
            )
            attempts.append(fallbackAttempt)
            authenticationDiagnostic = IMAPAuthenticationDiagnostic(
                endpoint: authenticationEndpoint,
                capabilities: capabilities,
                attempts: attempts,
                conclusion: .protocolFailure
            )
            if fallbackAttempt.completion == .ok {
                authenticationDiagnostic = IMAPAuthenticationDiagnostic(
                    endpoint: authenticationEndpoint,
                    capabilities: capabilities,
                    attempts: attempts,
                    conclusion: .connected
                )
                return
            }
        }

        let diagnostic = IMAPAuthenticationDiagnostic(
            endpoint: authenticationEndpoint,
            capabilities: capabilities,
            attempts: attempts,
            conclusion: .authenticationRejected
        )
        authenticationDiagnostic = diagnostic
        throw IMAPAuthenticationFailure(diagnostic: diagnostic)
    }

    private func authenticate(
        username: String,
        password: String,
        usernameMode: IMAPUsernameMode,
        method: IMAPAuthenticationMethod
    ) async throws -> IMAPAuthenticationAttempt {
        let tag = nextTag()
        switch method {
        case .login:
            let response = try await sendAndReceive(
                IMAPCommandBuilder.login(tag: tag, username: username, password: password),
                tag: tag
            )
            guard let status = IMAPResponseParser.completionStatus(tag: tag, in: response) else {
                throw IMAPProtocolError.malformedResponse
            }
            return IMAPAuthenticationAttempt(
                usernameMode: usernameMode,
                method: method,
                completion: status,
                sanitizedResponse: IMAPResponseParser.sanitizedAuthenticationResponse(tag: tag, in: response)
            )
        case .plain:
            try await send(IMAPCommandBuilder.authenticatePlainStart(tag: tag))
            var response = Data()
            while IMAPResponseParser.completionStatus(tag: tag, in: response) == nil,
                  !hasAuthenticationContinuation(in: response) {
                response.append(try await receiveChunk())
                guard response.count <= maximumResponseBytes else { throw NetworkIMAPError.oversizedResponse }
            }
            if let status = IMAPResponseParser.completionStatus(tag: tag, in: response) {
                return IMAPAuthenticationAttempt(
                    usernameMode: usernameMode,
                    method: method,
                    completion: status,
                    sanitizedResponse: IMAPResponseParser.sanitizedAuthenticationResponse(
                        tag: tag,
                        in: response
                    )
                )
            }
            guard hasAuthenticationContinuation(in: response) else {
                throw IMAPProtocolError.malformedResponse
            }
            try await send(IMAPCommandBuilder.authenticatePlainResponse(username: username, password: password))
            let completion = try await receiveUntilCompletion(tag: tag)
            guard let status = IMAPResponseParser.completionStatus(tag: tag, in: completion) else {
                throw IMAPProtocolError.malformedResponse
            }
            return IMAPAuthenticationAttempt(
                usernameMode: usernameMode,
                method: method,
                completion: status,
                sanitizedResponse: IMAPResponseParser.sanitizedAuthenticationResponse(
                    tag: tag,
                    in: completion
                )
            )
        }
    }

    private var authenticationEndpoint: IMAPConnectionEndpointDiagnostic {
        IMAPConnectionEndpointDiagnostic(
            host: account.host,
            port: account.port,
            usesTLS: account.useTLS
        )
    }

    private func authenticationConclusion(for error: Error) -> IMAPAuthenticationConclusion {
        if error is NWError {
            return .transportFailure
        }
        if let networkError = error as? NetworkIMAPError {
            switch networkError {
            case .connectionClosed, .tlsRequired, .invalidConfiguration:
                return .transportFailure
            case .invalidGreeting, .oversizedResponse:
                return .protocolFailure
            }
        }
        if error is IMAPProtocolError {
            return .protocolFailure
        }
        return .protocolFailure
    }

    private func receiveGreeting() async throws -> String {
        var data = Data()
        while data.range(of: Data("\r\n".utf8)) == nil {
            data.append(try await receiveChunk())
            guard data.count <= maximumResponseBytes else { throw NetworkIMAPError.oversizedResponse }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func sendAndReceive(_ command: String, tag: String) async throws -> Data {
        try await send(command)
        return try await receiveUntilCompletion(tag: tag)
    }

    private func send(_ command: String) async throws {
        guard let connection else { throw NetworkIMAPError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(command.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveUntilCompletion(tag: String) async throws -> Data {
        var response = Data()
        while IMAPResponseParser.completionStatus(tag: tag, in: response) == nil {
            response.append(try await receiveChunk())
            guard response.count <= maximumResponseBytes else { throw NetworkIMAPError.oversizedResponse }
        }
        return response
    }

    private func hasAuthenticationContinuation(in data: Data) -> Bool {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        return text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("+") }
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else { throw NetworkIMAPError.connectionClosed }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                data,
                _,
                isComplete,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: NetworkIMAPError.connectionClosed)
                } else {
                    continuation.resume(throwing: NetworkIMAPError.connectionClosed)
                }
            }
        }
    }
}
