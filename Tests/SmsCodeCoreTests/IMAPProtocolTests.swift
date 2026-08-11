import Foundation
import Testing
@testable import SmsCodeCore

struct IMAPProtocolTests {
    @Test func fakePerfect88ServerUsesLoginThenOneLocalPartFallbackOnlyAfterNo() throws {
        let capabilities = IMAPResponseParser.capabilitySummary(
            in: Data("* CAPABILITY IMAP4rev1 ID LITERAL+\r\nA1 OK done\r\n".utf8)
        )
        let primary = try #require(IMAPAuthenticationPlanner.primaryAttempt(capabilities: capabilities))
        #expect(primary.usernameMode == .fullAddress)
        #expect(primary.method == .login)

        let rejected = IMAPAuthenticationAttempt(
            usernameMode: primary.usernameMode,
            method: primary.method,
            completion: .no,
            sanitizedResponse: "登录信息或专用密码被服务端拒绝"
        )
        let fallback = try #require(
            IMAPAuthenticationPlanner.fallbackAttempt(after: rejected, usernameIsFullAddress: true)
        )
        #expect(fallback.usernameMode == .localPart)
        #expect(fallback.method == .login)
        #expect(
            IMAPAuthenticationPlanner.fallbackAttempt(
                after: IMAPAuthenticationAttempt(
                    usernameMode: fallback.usernameMode,
                    method: fallback.method,
                    completion: .no
                ),
                usernameIsFullAddress: true
            ) == nil
        )
    }

    @Test func fakePerfect88ServerUsesPlainOnlyWhenCapabilitiesRequireIt() throws {
        let disabledLogin = IMAPResponseParser.capabilitySummary(
            in: Data("* CAPABILITY IMAP4rev1 AUTH=PLAIN LOGINDISABLED\r\nA1 OK done\r\n".utf8)
        )
        let plain = try #require(IMAPAuthenticationPlanner.primaryAttempt(capabilities: disabledLogin))
        #expect(plain.usernameMode == .fullAddress)
        #expect(plain.method == .plain)

        let onlyPlain = IMAPResponseParser.capabilitySummary(
            in: Data("* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\nA1 OK done\r\n".utf8)
        )
        #expect(IMAPAuthenticationPlanner.primaryAttempt(capabilities: onlyPlain)?.method == .plain)

        let disabledWithoutPlain = IMAPResponseParser.capabilitySummary(
            in: Data("* CAPABILITY IMAP4rev1 LOGINDISABLED\r\nA1 OK done\r\n".utf8)
        )
        #expect(IMAPAuthenticationPlanner.primaryAttempt(capabilities: disabledWithoutPlain) == nil)
    }

    @Test func perfect88CapabilityStatesDistinguishUnavailableUndeclaredUnsupportedAndSupported() {
        let unavailable = IMAPResponseParser.capabilitySummary(
            in: Data("A1 OK CAPABILITY completed\r\n".utf8)
        )
        #expect(!unavailable.wasRetrieved)
        #expect(unavailable.plainSupport == .unavailable)
        #expect(unavailable.authLoginSupport == .unavailable)
        #expect(unavailable.loginCommandSupport == .unavailable)

        let recordedServer = IMAPResponseParser.capabilitySummary(
            in: Data(
                "* CAPABILITY IMAP4rev1 XLIST SPECIAL-USE ID LITERAL+ STARTTLS APPENDLIMIT=20971520 UIDPLUS\r\nA1 OK CAPABILITY completed\r\n".utf8
            )
        )
        #expect(recordedServer.wasRetrieved)
        #expect(recordedServer.plainSupport == .undeclared)
        #expect(recordedServer.authLoginSupport == .undeclared)
        #expect(recordedServer.loginCommandSupport == .undeclared)
        #expect(recordedServer.authenticationRelatedTokens == ["ID", "STARTTLS"])

        let supported = IMAPResponseParser.capabilitySummary(
            in: Data("* CAPABILITY IMAP4rev1 AUTH=PLAIN AUTH=LOGIN\r\nA1 OK done\r\n".utf8)
        )
        #expect(supported.plainSupport == .supported)
        #expect(supported.authLoginSupport == .supported)

        let unsupported = IMAPResponseParser.capabilitySummary(
            in: Data("* CAPABILITY IMAP4rev1 LOGINDISABLED\r\nA1 OK done\r\n".utf8)
        )
        #expect(unsupported.loginCommandSupport == .unsupported)
    }

    @Test func authenticationDiagnosticsAreBoundedAndDoNotContainCredentials() {
        let diagnostic = IMAPAuthenticationDiagnostic(
            endpoint: IMAPConnectionEndpointDiagnostic(host: "imap.88.com", port: 993, usesTLS: true),
            capabilities: IMAPCapabilitySummary(
                wasRetrieved: true,
                tokens: ["IMAP4rev1", "AUTH=PLAIN", "LOGINDISABLED"]
            ),
            attempts: [
                IMAPAuthenticationAttempt(
                    usernameMode: .fullAddress,
                    method: .plain,
                    completion: .no,
                    sanitizedResponse: "登录信息或专用密码被服务端拒绝"
                ),
                IMAPAuthenticationAttempt(usernameMode: .localPart, method: .login, completion: .no),
                IMAPAuthenticationAttempt(usernameMode: .localPart, method: .login, completion: .no)
            ],
            conclusion: .authenticationRejected
        )
        let text = diagnostic.displayText
        #expect(diagnostic.attempts.count == 2)
        #expect(text.contains("AUTH=PLAIN：支持"))
        #expect(text.contains("LOGIN 命令：明确不支持"))
        #expect(text.contains("隐式 TLS · imap.88.com:993"))
        #expect(text.contains("响应类别=NO"))
        #expect(text.contains("完整邮箱地址"))
        #expect(!text.contains("user@example.com"))
        #expect(!text.contains("secret"))
    }

    @Test func authenticationResponseIsClassifiedWithoutLeakingRawCredentials() {
        let raw = Data(
            "A9 NO [AUTHENTICATIONFAILED] Login error or password error\r\n".utf8
        )
        let sanitized = IMAPResponseParser.sanitizedAuthenticationResponse(tag: "A9", in: raw)

        #expect(sanitized == "登录信息或专用密码被服务端拒绝")
        #expect(!sanitized.contains("A9 NO"))
        #expect(!sanitized.contains("Login error"))
    }

    @Test func buildsReadOnlyUIDAndPeekCommands() {
        #expect(IMAPCommandBuilder.examineInbox(tag: "A1") == "A1 EXAMINE INBOX\r\n")
        #expect(IMAPCommandBuilder.search(afterUID: 41, tag: "A2") == "A2 UID SEARCH UID 42:*\r\n")
        #expect(IMAPCommandBuilder.fetch(uid: 42, tag: "A3").contains("BODY.PEEK[]"))
        #expect(!IMAPCommandBuilder.fetch(uid: 42, tag: "A3").contains("STORE"))
        #expect(IMAPCommandBuilder.clientID(tag: "A4").contains(" ID "))
    }

    @Test func loginEscapesValuesWithoutAddingLogsOrArguments() {
        let command = IMAPCommandBuilder.login(
            tag: "A1",
            username: "user@example.com",
            password: "a\"b\\c\nignored"
        )
        #expect(command.hasPrefix("A1 LOGIN "))
        #expect(command.contains("a\\\"b\\\\cignored"))
        #expect(!command.contains("\nignored\n"))
    }

    @Test func parsesSegmentedCompletionUIDValidityAndSearchResults() throws {
        let first = Data("* OK [UIDVALIDITY 777] UIDs valid\r\n* SEARCH 10 11".utf8)
        #expect(IMAPResponseParser.completionStatus(tag: "A9", in: first) == nil)
        var complete = first
        complete.append(Data(" 12\r\nA9 OK done\r\n".utf8))

        #expect(IMAPResponseParser.completionStatus(tag: "A9", in: complete) == .ok)
        #expect(try IMAPResponseParser.uidValidity(in: complete) == 777)
        #expect(IMAPResponseParser.searchUIDs(in: complete) == [10, 11, 12])
        try IMAPResponseParser.requireOK(tag: "A9", in: complete)
    }

    @Test func extractsLiteralAndInternalDateWithoutChangingMessageState() throws {
        let message = "Subject: Verification code\r\nContent-Type: text/plain\r\n\r\nCode 123456"
        var response = Data("* 1 FETCH (UID 42 INTERNALDATE \"12-Jul-2026 10:11:12 +0800\" BODY[] {\(message.utf8.count)}\r\n".utf8)
        response.append(Data(message.utf8))
        response.append(Data("\r\n)\r\nA5 OK FETCH completed\r\n".utf8))

        #expect(try IMAPResponseParser.literal(in: response) == Data(message.utf8))
        #expect(IMAPResponseParser.internalDate(in: response) != nil)
    }

    @Test func recordedQQStyleFetchLiteralDecodesToVerificationCode() throws {
        let message = [
            "Subject: =?UTF-8?B?55m75b2V6aqM6K+B56CB?=",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            Data("你正在登录测试服务，登录验证码为 739516，请勿泄露。".utf8).base64EncodedString()
        ].joined(separator: "\r\n")
        var response = Data("* 7 FETCH (UID 109 INTERNALDATE \"12-Jul-2026 10:11:12 +0800\" BODY[] {\(message.utf8.count)}\r\n".utf8)
        response.append(Data(message.utf8))
        response.append(Data("\r\n)\r\nA5 OK FETCH completed\r\n".utf8))

        let literal = try IMAPResponseParser.literal(in: response)
        let content = try EmailMIMEParser().parse(literal)
        let candidate = EmailVerificationCodeSelector().candidate(
            from: EmailVerificationMessage(
                accountID: UUID(),
                uid: 109,
                date: Date().addingTimeInterval(-1),
                subject: content.subject,
                body: content.body
            )
        )

        #expect(content.subject == "登录验证码")
        #expect(candidate?.code == "739516")
    }

    @Test func rejectsFailedTaggedResponse() {
        let response = Data("A1 NO authentication failed\r\n".utf8)
        #expect(throws: IMAPProtocolError.self) {
            try IMAPResponseParser.requireOK(tag: "A1", in: response)
        }
    }
}
