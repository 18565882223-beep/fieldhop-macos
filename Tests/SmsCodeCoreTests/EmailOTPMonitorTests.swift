import Foundation
import Testing
@testable import SmsCodeCore

private enum FakeIMAPError: Error, LocalizedError {
    case connection

    var errorDescription: String? { "fake connection failed" }
}

private final class FakeIMAPClient: IMAPMailboxClient {
    let state: IMAPMailboxState
    var batches: [[EmailVerificationMessage]]
    var remainingConnectFailures: Int
    private(set) var connectCount = 0
    private(set) var fetchedAfterUIDs: [UInt64] = []
    private(set) var disconnectCount = 0

    init(
        state: IMAPMailboxState,
        batches: [[EmailVerificationMessage]] = [],
        remainingConnectFailures: Int = 0
    ) {
        self.state = state
        self.batches = batches
        self.remainingConnectFailures = remainingConnectFailures
    }

    func connect(username: String, password: String, requiresClientID: Bool) async throws {
        connectCount += 1
        if remainingConnectFailures > 0 {
            remainingConnectFailures -= 1
            throw FakeIMAPError.connection
        }
    }

    func mailboxState() async throws -> IMAPMailboxState { state }

    func fetchMessages(afterUID: UInt64) async throws -> EmailMessageFetchBatch {
        fetchedAfterUIDs.append(afterUID)
        let messages = batches.isEmpty ? [] : batches.removeFirst()
        return EmailMessageFetchBatch(
            discoveredUIDs: messages.map(\.uid),
            messages: messages,
            diagnostics: messages.map {
                EmailMessageFetchDiagnostic(uid: $0.uid, fetchSucceeded: true, mimeSucceeded: true)
            }
        )
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func cancel() {
        disconnectCount += 1
    }
}

struct EmailOTPMonitorTests {
    @Test @MainActor func firstConnectionEstablishesWatermarkBeforeFetchingNewMail() async throws {
        let id = UUID()
        let newMessage = EmailVerificationMessage(
            accountID: id,
            uid: 6,
            date: Date().addingTimeInterval(-1),
            subject: "验证码",
            body: "验证码 654321"
        )
        let client = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 7, maximumUID: 5),
            batches: [[newMessage]]
        )
        var watermarks: [(UInt64, UInt64)] = []
        var candidates: [VerificationCodeCandidate] = []
        let monitor = EmailOTPMonitor(
            clientFactory: { _ in client },
            credentialProvider: { _ in "secret" },
            pollNanoseconds: 3_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { candidates.append($0) },
            onStatus: { _, _ in },
            onWatermark: { _, validity, uid in watermarks.append((validity, uid)) }
        )
        let account = EmailAccount(
            id: id,
            displayName: "邮箱",
            emailAddress: "a@example.com",
            host: "imap.example.com"
        )

        monitor.synchronize(accounts: [account], isEnabled: true)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            candidates.count == 1
        }
        monitor.stopAll()

        #expect(watermarks.first?.0 == 7)
        #expect(watermarks.first?.1 == 5)
        #expect(client.fetchedAfterUIDs.first == 5)
        #expect(candidates.map(\.code) == ["654321"])
    }

    @Test @MainActor func qqStyleMailAfterWatermarkReachesCandidateAndAdvancesWatermark() async throws {
        let id = UUID()
        let message = EmailVerificationMessage(
            accountID: id,
            uid: 109,
            date: Date().addingTimeInterval(-1),
            subject: "登录验证码",
            body: "你正在登录测试服务，登录验证码为 739516，请勿泄露。"
        )
        let client = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 88, maximumUID: 108),
            batches: [[message]]
        )
        var watermarks: [(UInt64, UInt64)] = []
        var statuses: [EmailConnectionStatus] = []
        var candidates: [VerificationCodeCandidate] = []
        let monitor = EmailOTPMonitor(
            clientFactory: { _ in client },
            credentialProvider: { _ in "same-keychain-secret" },
            pollNanoseconds: 3_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { candidates.append($0) },
            onStatus: { _, status in statuses.append(status) },
            onWatermark: { _, validity, uid in watermarks.append((validity, uid)) }
        )
        let account = EmailAccount(
            id: id,
            displayName: "QQ",
            emailAddress: "q@example.com",
            host: "imap.qq.com",
            uidValidity: 88,
            lastSeenUID: 108
        )

        monitor.synchronize(accounts: [account], isEnabled: true)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            candidates.count == 1
        }
        monitor.stopAll()

        #expect(client.fetchedAfterUIDs.first == 108)
        #expect(candidates.first?.code == "739516")
        #expect(watermarks.contains { $0 == (88, 109) })
        #expect(statuses.contains { status in
            status.diagnostic?.discoveredUIDCount == 1
                && status.diagnostic?.fetchSucceededCount == 1
                && status.diagnostic?.mimeSucceededCount == 1
                && status.diagnostic?.keywordMatchedCount == 1
                && status.diagnostic?.codeExtractedCount == 1
        })
    }

    @Test @MainActor func failedMimeDoesNotAdvanceWatermarkPastFailedUID() async throws {
        let id = UUID()
        let client = PartialFailureIMAPClient(
            state: IMAPMailboxState(uidValidity: 9, maximumUID: 100),
            batch: EmailMessageFetchBatch(
                discoveredUIDs: [101, 102],
                messages: [
                    EmailVerificationMessage(
                        accountID: id,
                        uid: 102,
                        date: Date().addingTimeInterval(-1),
                        subject: "登录验证码",
                        body: "登录验证码 123456"
                    )
                ],
                diagnostics: [
                    EmailMessageFetchDiagnostic(
                        uid: 101,
                        fetchSucceeded: true,
                        mimeSucceeded: false,
                        sanitizedError: "malformed"
                    ),
                    EmailMessageFetchDiagnostic(uid: 102, fetchSucceeded: true, mimeSucceeded: true)
                ]
            )
        )
        var watermarks: [(UInt64, UInt64)] = []
        var statuses: [EmailConnectionStatus] = []
        var candidates: [VerificationCodeCandidate] = []
        let monitor = EmailOTPMonitor(
            clientFactory: { _ in client },
            credentialProvider: { _ in "secret" },
            pollNanoseconds: 50_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { candidates.append($0) },
            onStatus: { _, status in statuses.append(status) },
            onWatermark: { _, validity, uid in watermarks.append((validity, uid)) }
        )
        let account = EmailAccount(
            id: id,
            displayName: "邮箱",
            emailAddress: "a@example.com",
            host: "imap.example.com",
            uidValidity: 9,
            lastSeenUID: 100
        )

        monitor.synchronize(accounts: [account], isEnabled: true)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            candidates.count == 1
        }
        monitor.stopAll()

        #expect(candidates.first?.code == "123456")
        #expect(!watermarks.contains { $0.1 >= 102 })
        #expect(statuses.contains { status in
            status.diagnostic?.discoveredUIDCount == 2
                && status.diagnostic?.mimeFailedCount == 1
                && status.diagnostic?.lastSanitizedError == "malformed"
        })
    }

    @Test @MainActor func twoAccountsPollIndependentlyAndEmitsOneCandidate() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstClient = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 1, maximumUID: 10),
            batches: [[EmailVerificationMessage(
                accountID: firstID,
                uid: 11,
                date: Date().addingTimeInterval(-2),
                subject: "OTP",
                body: "OTP 111111"
            )]]
        )
        let secondClient = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 2, maximumUID: 20),
            batches: [[EmailVerificationMessage(
                accountID: secondID,
                uid: 21,
                date: Date().addingTimeInterval(-1),
                subject: "验证码",
                body: "验证码 222222"
            )]]
        )
        var candidates: [VerificationCodeCandidate] = []
        let monitor = EmailOTPMonitor(
            clientFactory: { account in account.id == firstID ? firstClient : secondClient },
            credentialProvider: { _ in "secret" },
            pollNanoseconds: 3_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { candidates.append($0) },
            onStatus: { _, _ in },
            onWatermark: { _, _, _ in }
        )
        let accounts = [
            EmailAccount(id: firstID, displayName: "一", emailAddress: "a@example.com", host: "imap.example.com", uidValidity: 1, lastSeenUID: 10),
            EmailAccount(id: secondID, displayName: "二", emailAddress: "b@example.com", host: "imap.example.com", uidValidity: 2, lastSeenUID: 20)
        ]

        monitor.synchronize(accounts: accounts, isEnabled: true)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            candidates.count == 1
        }
        monitor.stopAll()

        #expect(!firstClient.fetchedAfterUIDs.isEmpty)
        #expect(!secondClient.fetchedAfterUIDs.isEmpty)
        #expect(candidates.count == 1)
    }

    @Test @MainActor func twoMessagesArrivingTogetherSelectNewestHighConfidenceCandidate() async throws {
        let id = UUID()
        let now = Date()
        let first = EmailVerificationMessage(
            accountID: id,
            uid: 31,
            date: now.addingTimeInterval(-20),
            subject: "登录验证码",
            body: "验证码 111111"
        )
        let second = EmailVerificationMessage(
            accountID: id,
            uid: 32,
            date: now.addingTimeInterval(-10),
            subject: "Sign in",
            body: "Use 222222 to sign in"
        )
        let client = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 3, maximumUID: 30),
            batches: [[first, second]]
        )
        var candidates: [VerificationCodeCandidate] = []
        let monitor = EmailOTPMonitor(
            clientFactory: { _ in client },
            credentialProvider: { _ in "secret" },
            pollNanoseconds: 3_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { candidates.append($0) },
            onStatus: { _, _ in },
            onWatermark: { _, _, _ in }
        )
        let account = EmailAccount(
            id: id,
            displayName: "邮箱",
            emailAddress: "a@example.com",
            host: "imap.example.com",
            uidValidity: 3,
            lastSeenUID: 30
        )

        monitor.synchronize(accounts: [account], isEnabled: true)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            candidates.count == 1
        }
        monitor.stopAll()

        #expect(candidates.map(\.code) == ["222222"])
    }

    @Test @MainActor func mediumConfidenceUpdatesDiagnosticWithoutEmittingCandidate() async throws {
        let id = UUID()
        let message = EmailVerificationMessage(
            accountID: id,
            uid: 41,
            date: Date().addingTimeInterval(-1),
            subject: "重置密码",
            body: "验证码 482731 用于重置密码。"
        )
        let client = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 4, maximumUID: 40),
            batches: [[message], []]
        )
        var candidates: [VerificationCodeCandidate] = []
        var statuses: [EmailConnectionStatus] = []
        let monitor = EmailOTPMonitor(
            clientFactory: { _ in client },
            credentialProvider: { _ in "secret" },
            pollNanoseconds: 3_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { candidates.append($0) },
            onStatus: { _, status in statuses.append(status) },
            onWatermark: { _, _, _ in }
        )
        let account = EmailAccount(
            id: id,
            displayName: "邮箱",
            emailAddress: "a@example.com",
            host: "imap.example.com",
            uidValidity: 4,
            lastSeenUID: 40
        )

        monitor.synchronize(accounts: [account], isEnabled: true)
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            statuses.contains { $0.diagnostic?.mediumConfidenceCount == 1 }
        }
        monitor.stopAll()

        #expect(candidates.isEmpty)
        #expect(statuses.contains { status in
            status.diagnosticText.contains("发现疑似验证码，需手动确认")
                && !status.diagnosticText.contains("482731")
        })
    }

    @Test @MainActor func reconnectsWithBackoffAndCancellationDisconnectsClient() async throws {
        let id = UUID()
        let client = FakeIMAPClient(
            state: IMAPMailboxState(uidValidity: 1, maximumUID: 0),
            remainingConnectFailures: 1
        )
        let scheduler = ControlledSleeper()
        let monitor = EmailOTPMonitor(
            clientFactory: { _ in client },
            credentialProvider: { _ in "secret" },
            pollNanoseconds: 5_000_000,
            backoffNanoseconds: [1_000_000],
            onCandidate: { _ in },
            onStatus: { _, _ in },
            onWatermark: { _, _, _ in },
            sleepHandler: { nanoseconds in
                try await scheduler.sleep(nanoseconds: nanoseconds)
            }
        )
        let account = EmailAccount(
            id: id,
            displayName: "邮箱",
            emailAddress: "a@example.com",
            host: "imap.example.com"
        )

        monitor.synchronize(accounts: [account], isEnabled: true)
        try await yieldUntil(maxYields: 100) {
            client.connectCount == 2 && scheduler.requestedNanoseconds.first == 1_000_000
        }
        monitor.synchronize(accounts: [], isEnabled: false)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(client.connectCount == 2)
        #expect(client.disconnectCount >= 2)
        #expect(scheduler.requestedNanoseconds.first == 1_000_000)
        #expect(monitor.status(for: id).phase == .stopped)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while !(await condition()) {
            guard Date() < deadline else {
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func yieldUntil(
        maxYields: Int,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<maxYields {
            if await condition() { return }
            await Task.yield()
        }
        throw TimeoutError()
    }
}

@MainActor
private final class ControlledSleeper {
    private(set) var requestedNanoseconds: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        requestedNanoseconds.append(nanoseconds)
        if requestedNanoseconds.count == 1 {
            return
        }
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

private final class PartialFailureIMAPClient: IMAPMailboxClient {
    let state: IMAPMailboxState
    let batch: EmailMessageFetchBatch

    init(state: IMAPMailboxState, batch: EmailMessageFetchBatch) {
        self.state = state
        self.batch = batch
    }

    func connect(username: String, password: String, requiresClientID: Bool) async throws {}

    func mailboxState() async throws -> IMAPMailboxState { state }

    func fetchMessages(afterUID: UInt64) async throws -> EmailMessageFetchBatch { batch }

    func disconnect() async {}

    func cancel() {}
}

private struct TimeoutError: Error {}
