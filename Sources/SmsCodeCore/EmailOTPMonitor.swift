import Foundation

public enum EmailOTPMonitorError: Error, LocalizedError, Equatable {
    case missingCredential

    public var errorDescription: String? {
        switch self {
        case .missingCredential: return "未找到应用专用密码"
        }
    }
}

@MainActor
public final class EmailOTPMonitor {
    public typealias ClientFactory = (EmailAccount) -> IMAPMailboxClient
    public typealias CredentialProvider = (UUID) -> String?
    public typealias CandidateHandler = (VerificationCodeCandidate) -> Void
    public typealias StatusHandler = (UUID, EmailConnectionStatus) -> Void
    public typealias WatermarkHandler = (UUID, UInt64, UInt64) -> Void
    public typealias ReadyHandler = (UUID) -> Void
    public typealias SleepHandler = (UInt64) async throws -> Void

    private struct PendingCandidate {
        let candidate: VerificationCodeCandidate
        let key: String
        let messageDate: Date
        let arrivalOrder: UInt64
    }

    private let clientFactory: ClientFactory
    private let credentialProvider: CredentialProvider
    private let selector: EmailVerificationCodeSelector
    private let pollNanoseconds: UInt64
    private let backoffNanoseconds: [UInt64]
    private let onCandidate: CandidateHandler
    private let onStatus: StatusHandler
    private let onWatermark: WatermarkHandler
    private let onReady: ReadyHandler?
    private let sleepHandler: SleepHandler
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var taskGenerations: [UUID: UUID] = [:]
    private var activeClients: [UUID: IMAPMailboxClient] = [:]
    private var configuredAccounts: [UUID: EmailAccount] = [:]
    private var statuses: [UUID: EmailConnectionStatus] = [:]
    private var diagnostics: [UUID: EmailPollDiagnostic] = [:]
    private var handledKeys = Set<String>()
    private var pendingCandidates: [PendingCandidate] = []
    private var candidateFlushTask: Task<Void, Never>?
    private var arrivalCounter: UInt64 = 0
    private var waitingAccountID: UUID?

    public init(
        clientFactory: @escaping ClientFactory,
        credentialProvider: @escaping CredentialProvider,
        selector: EmailVerificationCodeSelector = EmailVerificationCodeSelector(),
        pollNanoseconds: UInt64 = 5_000_000_000,
        backoffNanoseconds: [UInt64] = [2, 5, 10, 30].map { $0 * 1_000_000_000 },
        onCandidate: @escaping CandidateHandler,
        onStatus: @escaping StatusHandler,
        onWatermark: @escaping WatermarkHandler,
        onReady: ReadyHandler? = nil,
        sleepHandler: @escaping SleepHandler = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.clientFactory = clientFactory
        self.credentialProvider = credentialProvider
        self.selector = selector
        self.pollNanoseconds = pollNanoseconds
        self.backoffNanoseconds = backoffNanoseconds.isEmpty ? [30_000_000_000] : backoffNanoseconds
        self.onCandidate = onCandidate
        self.onStatus = onStatus
        self.onWatermark = onWatermark
        self.onReady = onReady
        self.sleepHandler = sleepHandler
    }

    public func synchronize(accounts: [EmailAccount], isEnabled: Bool) {
        let desired = isEnabled
            ? Dictionary(uniqueKeysWithValues: accounts.filter(\.isEnabled).map { ($0.id, $0) })
            : [:]

        let removedIDs = tasks.keys.filter { id in
            desired[id] == nil || configuredAccounts[id] != desired[id]
        }
        for id in removedIDs {
            activeClients[id]?.cancel()
            activeClients[id] = nil
            tasks[id]?.cancel()
            tasks[id] = nil
            taskGenerations[id] = nil
            configuredAccounts[id] = nil
            diagnostics[id] = diagnostics[id] ?? EmailPollDiagnostic()
            updateStatus(id: id, status: EmailConnectionStatus(phase: .stopped))
        }

        for (id, account) in desired where tasks[id] == nil {
            let generation = UUID()
            taskGenerations[id] = generation
            configuredAccounts[id] = account
            diagnostics[id] = diagnostics[id] ?? EmailPollDiagnostic()
            tasks[id] = Task { [weak self] in
                await self?.run(account: account, generation: generation, forceInitialWatermark: false)
            }
        }
    }

    /// 临时等待只保留一个账号，并在本次连接中重新建立 UID 水位线。
    public func startWaiting(account: EmailAccount) {
        stopAll()
        waitingAccountID = account.id
        let generation = UUID()
        taskGenerations[account.id] = generation
        configuredAccounts[account.id] = account
        diagnostics[account.id] = EmailPollDiagnostic()
        tasks[account.id] = Task { [weak self] in
            await self?.run(account: account, generation: generation, forceInitialWatermark: true)
        }
    }

    public func stopAll() {
        for client in activeClients.values { client.cancel() }
        activeClients.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        taskGenerations.removeAll()
        configuredAccounts.removeAll()
        diagnostics.removeAll()
        candidateFlushTask?.cancel()
        candidateFlushTask = nil
        pendingCandidates.removeAll()
        waitingAccountID = nil
    }

    public func status(for accountID: UUID) -> EmailConnectionStatus {
        statuses[accountID] ?? EmailConnectionStatus(phase: .stopped)
    }

    private func run(account: EmailAccount, generation: UUID, forceInitialWatermark: Bool) async {
        var runtimeAccount = account
        var backoffIndex = 0

        while !Task.isCancelled {
            let client = clientFactory(runtimeAccount)
            if taskGenerations[account.id] == generation {
                activeClients[account.id] = client
            }
            do {
                updateStatus(id: account.id, status: EmailConnectionStatus(phase: .connecting))
                guard let password = credentialProvider(account.id) else {
                    throw EmailOTPMonitorError.missingCredential
                }
                try await client.connect(
                    username: runtimeAccount.username,
                    password: password,
                    requiresClientID: runtimeAccount.requiresIMAPID
                )
                try ensureTaskIsActive(accountID: account.id, generation: generation)
                let state = try await client.mailboxState()
                try ensureTaskIsActive(accountID: account.id, generation: generation)

                if forceInitialWatermark || runtimeAccount.uidValidity != state.uidValidity || runtimeAccount.lastSeenUID == nil {
                    runtimeAccount.uidValidity = state.uidValidity
                    runtimeAccount.lastSeenUID = state.maximumUID
                    onWatermark(account.id, state.uidValidity, state.maximumUID)
                    updateStatus(
                        id: account.id,
                        status: EmailConnectionStatus(phase: .listening, detail: "已建立 UID 水位线")
                    )
                } else {
                    updateStatus(id: account.id, status: EmailConnectionStatus(phase: .listening))
                }
                onReady?(account.id)
                backoffIndex = 0
                let listeningStartedAt = Date()

                while !Task.isCancelled {
                    let lastSeenUID = runtimeAccount.lastSeenUID ?? state.maximumUID
                    let batch = try await client.fetchMessages(afterUID: lastSeenUID)
                    try ensureTaskIsActive(accountID: account.id, generation: generation)
                    let candidateStats = enqueue(messages: batch.messages)
                    let diagnostic = makeSuccessfulPollDiagnostic(batch: batch, candidateStats: candidateStats)
                    diagnostics[account.id] = diagnostic
                    updateStatus(
                        id: account.id,
                        status: EmailConnectionStatus(phase: .listening, diagnostic: diagnostic)
                    )
                    if let advancedUID = highestAdvanceableUID(
                        afterUID: lastSeenUID,
                        diagnostics: batch.diagnostics
                    ) {
                        runtimeAccount.lastSeenUID = advancedUID
                        onWatermark(account.id, state.uidValidity, advancedUID)
                    }
                    let interval = Date().timeIntervalSince(listeningStartedAt) < 120
                        ? min(pollNanoseconds, 2_000_000_000)
                        : pollNanoseconds
                    try await sleepHandler(interval)
                }
            } catch is CancellationError {
                await client.disconnect()
                break
            } catch {
                await client.disconnect()
                guard !Task.isCancelled else { break }
                let delay = backoffNanoseconds[min(backoffIndex, backoffNanoseconds.count - 1)]
                backoffIndex = min(backoffIndex + 1, backoffNanoseconds.count - 1)
                let detail = EmailLogSanitizer.sanitizeError(error.localizedDescription)
                diagnostics[account.id] = makeFailedPollDiagnostic(accountID: account.id, error: detail)
                updateStatus(
                    id: account.id,
                    status: EmailConnectionStatus(
                        phase: .retrying,
                        detail: detail,
                        diagnostic: diagnostics[account.id]
                    )
                )
                do {
                    try await sleepHandler(delay)
                } catch {
                    break
                }
            }
        }

        if taskGenerations[account.id] == generation {
            updateStatus(id: account.id, status: EmailConnectionStatus(phase: .stopped))
            activeClients[account.id] = nil
            tasks[account.id] = nil
            taskGenerations[account.id] = nil
            configuredAccounts[account.id] = nil
        }
    }

    private struct CandidateStats {
        var keywordMatchedCount = 0
        var codeExtractedCount = 0
        var highConfidenceCount = 0
        var mediumConfidenceCount = 0
        var lowConfidenceCount = 0
        var lastExtractionSummary: String?
    }

    @discardableResult
    private func enqueue(messages: [EmailVerificationMessage], now: Date = Date()) -> CandidateStats {
        var stats = CandidateStats()
        for message in messages {
            let searchable = "\(message.subject)\n\(message.body)"
            let hasKeyword = selector.extractor.containsKeyword(searchable)
            if hasKeyword {
                stats.keywordMatchedCount += 1
            }
            let assessment = selector.assess(message: message)
            stats.lastExtractionSummary = assessment.sanitizedSummary
            switch assessment.confidence {
            case .high:
                stats.highConfidenceCount += 1
            case .medium:
                stats.mediumConfidenceCount += 1
            case .low:
                stats.lowConfidenceCount += 1
            }
            let waitResult = waitingAccountID == message.accountID ? selector.waitingResult(message: message) : nil
            if case let .ambiguous(summary)? = waitResult {
                stats.lastExtractionSummary = "歧义，\(summary)"
                continue
            }
            let code: String?
            if case let .code(value)? = waitResult {
                code = value
            } else {
                code = assessment.confidence == .high ? selector.candidate(from: message, now: now)?.code : nil
            }
            guard let code else {
                continue
            }
            let candidate = VerificationCodeCandidate(
                code: code,
                date: now,
                source: .email(accountID: message.accountID, uid: message.uid)
            )
            stats.codeExtractedCount += 1
            let key = "\(message.accountID.uuidString):\(message.uid):\(candidate.code)"
            guard !handledKeys.contains(key) else { continue }
            arrivalCounter &+= 1
            pendingCandidates.append(
                PendingCandidate(candidate: candidate, key: key, messageDate: message.date, arrivalOrder: arrivalCounter)
            )
        }
        guard !pendingCandidates.isEmpty, candidateFlushTask == nil else { return stats }
        candidateFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.flushCandidates()
        }
        return stats
    }

    private func flushCandidates() {
        candidateFlushTask = nil
        guard !pendingCandidates.isEmpty else { return }
        let candidates = pendingCandidates
        pendingCandidates.removeAll()
        for item in candidates { handledKeys.insert(item.key) }
        let selected = candidates.sorted { lhs, rhs in
            if lhs.candidate.date != rhs.candidate.date {
                return lhs.candidate.date > rhs.candidate.date
            }
            if let lhsUID = emailUID(lhs.candidate),
               let rhsUID = emailUID(rhs.candidate),
               sameEmailAccount(lhs.candidate, rhs.candidate),
               lhsUID != rhsUID {
                return lhsUID > rhsUID
            }
            if lhs.messageDate != rhs.messageDate {
                return lhs.messageDate > rhs.messageDate
            }
            return lhs.arrivalOrder < rhs.arrivalOrder
        }.first
        if let selected {
            onCandidate(selected.candidate)
        }
    }

    private func emailUID(_ candidate: VerificationCodeCandidate) -> UInt64? {
        guard case let .email(_, uid) = candidate.source else { return nil }
        return uid
    }

    private func sameEmailAccount(
        _ lhs: VerificationCodeCandidate,
        _ rhs: VerificationCodeCandidate
    ) -> Bool {
        guard case let .email(lhsID, _) = lhs.source,
              case let .email(rhsID, _) = rhs.source else {
            return false
        }
        return lhsID == rhsID
    }

    private func updateStatus(id: UUID, status: EmailConnectionStatus) {
        let mergedStatus: EmailConnectionStatus
        if status.diagnostic == nil, let diagnostic = diagnostics[id] {
            mergedStatus = EmailConnectionStatus(
                phase: status.phase,
                detail: status.detail,
                diagnostic: diagnostic
            )
        } else {
            mergedStatus = status
        }
        statuses[id] = mergedStatus
        onStatus(id, mergedStatus)
    }

    private func ensureTaskIsActive(accountID: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard taskGenerations[accountID] == generation else {
            throw CancellationError()
        }
    }

    private func makeSuccessfulPollDiagnostic(
        batch: EmailMessageFetchBatch,
        candidateStats: CandidateStats
    ) -> EmailPollDiagnostic {
        let fetchSucceeded = batch.diagnostics.filter(\.fetchSucceeded).count
        let fetchFailed = batch.diagnostics.filter { !$0.fetchSucceeded }.count
        let mimeSucceeded = batch.diagnostics.filter(\.mimeSucceeded).count
        let mimeFailed = batch.diagnostics.filter { $0.fetchSucceeded && !$0.mimeSucceeded }.count
        return EmailPollDiagnostic(
            lastPollAt: Date(),
            lastPollSucceeded: true,
            discoveredUIDCount: batch.discoveredUIDs.count,
            fetchSucceededCount: fetchSucceeded,
            fetchFailedCount: fetchFailed,
            mimeSucceededCount: mimeSucceeded,
            mimeFailedCount: mimeFailed,
            keywordMatchedCount: candidateStats.keywordMatchedCount,
            codeExtractedCount: candidateStats.codeExtractedCount,
            highConfidenceCount: candidateStats.highConfidenceCount,
            mediumConfidenceCount: candidateStats.mediumConfidenceCount,
            lowConfidenceCount: candidateStats.lowConfidenceCount,
            lastExtractionSummary: candidateStats.lastExtractionSummary,
            lastSanitizedError: batch.diagnostics.last(where: { $0.sanitizedError != nil })?.sanitizedError
        )
    }

    private func makeFailedPollDiagnostic(accountID: UUID, error: String) -> EmailPollDiagnostic {
        var diagnostic = diagnostics[accountID] ?? EmailPollDiagnostic()
        diagnostic.lastPollAt = Date()
        diagnostic.lastPollSucceeded = false
        diagnostic.lastSanitizedError = error
        return diagnostic
    }

    private func highestAdvanceableUID(
        afterUID: UInt64,
        diagnostics: [EmailMessageFetchDiagnostic]
    ) -> UInt64? {
        var expected = afterUID == UInt64.max ? UInt64.max : afterUID + 1
        var advanced: UInt64?
        for diagnostic in diagnostics.sorted(by: { $0.uid < $1.uid }) {
            guard diagnostic.uid == expected else { break }
            guard diagnostic.canAdvanceWatermark else { break }
            advanced = diagnostic.uid
            if expected == UInt64.max { break }
            expected += 1
        }
        return advanced
    }
}
