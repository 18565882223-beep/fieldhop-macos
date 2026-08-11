import Foundation
import Testing
@testable import SmsCodeCore

struct EmailAccountTests {
    @Test func oldAccountDataMigratesShortcutAndWaitDurationWithoutChangingID() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","displayName":"旧账号","emailAddress":"old@example.com","host":"imap.example.com","port":993,"useTLS":true,"username":"old@example.com","isEnabled":true}
        """
        let account = try JSONDecoder().decode(EmailAccount.self, from: Data(json.utf8))
        #expect(account.id == id)
        #expect(account.waitDurationMinutes == 10)
        #expect(account.shortcut.displayName == "⌥⌘4")
    }
    @Test func accountMetadataRoundTripsWithoutPassword() throws {
        let account = EmailAccount(
            displayName: "工作邮箱",
            emailAddress: "person@example.com",
            host: "imap.example.com",
            username: "person@example.com",
            uidValidity: 42,
            lastSeenUID: 108
        )
        let list = EmailAccountList(accounts: [account])
        let data = try JSONEncoder().encode(list)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(EmailAccountList.self, from: data)

        #expect(decoded == list)
        #expect(!json.lowercased().contains("password"))
        #expect(account.maskedEmail == "p***@example.com")
    }

    @Test func presetsUseExpectedSecureEndpoints() {
        #expect(EmailProviderPreset.gmail.host == "imap.gmail.com")
        #expect(EmailProviderPreset.outlook.host == "outlook.office365.com")
        #expect(EmailProviderPreset.qq.host == "imap.qq.com")
        #expect(EmailProviderPreset.perfect88.host == "imap.88.com")
        #expect(EmailProviderPreset.perfect88.port == 993)
        #expect(EmailProviderPreset.perfect88.useTLS)
        #expect(EmailProviderPreset.perfect88.matches(emailAddress: "user@88.com"))
        #expect(!EmailProviderPreset.perfect88.matches(emailAddress: "user@188.com"))
        #expect(EmailProviderPreset.netease163.host == "imap.163.com")
        #expect(EmailProviderPreset.netease126.host == "imap.126.com")
        #expect(EmailProviderPreset.gmail.port == 993)
        #expect(EmailProviderPreset.gmail.useTLS)
    }

    @Test func perfect88IsRecognizedWithoutChangingOtherProviderAuthentication() {
        let perfect88 = EmailAccount(
            displayName: "88 邮箱",
            emailAddress: "user@88.com",
            host: "imap.88.com"
        )
        let netease = EmailAccount(
            displayName: "163 邮箱",
            emailAddress: "user@163.com",
            host: "imap.163.com"
        )
        let qq = EmailAccount(
            displayName: "QQ 邮箱",
            emailAddress: "user@qq.com",
            host: "imap.qq.com"
        )

        #expect(perfect88.isPerfect88IMAP)
        #expect(!perfect88.requiresIMAPID)
        #expect(netease.requiresIMAPID)
        #expect(!netease.isPerfect88IMAP)
        #expect(!qq.requiresIMAPID)
        #expect(!qq.isPerfect88IMAP)
    }

    @Test func storeRestoresAccountsAndGlobalSwitch() throws {
        let suite = "EmailAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EmailAccountStore(defaults: defaults)
        let account = EmailAccount(
            displayName: "QQ",
            emailAddress: "user@qq.com",
            host: "imap.qq.com"
        )

        try store.save(EmailAccountList(accounts: [account]))
        store.isMonitoringEnabled = false

        #expect(store.load().accounts == [account])
        #expect(!store.isMonitoringEnabled)
    }

    @Test func logSanitizerRemovesAddressAndLongSecrets() {
        let text = EmailLogSanitizer.sanitizeError(
            "login person@example.com failed token AbCdEfGhIjKlMnOpQrSt"
        )
        #expect(!text.contains("person@example.com"))
        #expect(!text.contains("AbCdEfGhIjKlMnOpQrSt"))
        #expect(text.contains("***@***"))
    }
}

private final class MemoryEmailCredentialBackend: EmailCredentialBackend {
    var values: [String: Data] = [:]
    var failSave = false

    func load(service: String, account: String) -> Data? {
        values["\(service):\(account)"]
    }

    func save(_ data: Data, service: String, account: String) throws {
        if failSave { throw CredentialBackendTestError.failed }
        values["\(service):\(account)"] = data
    }

    func delete(service: String, account: String) throws {
        values["\(service):\(account)"] = nil
    }
}

private enum CredentialBackendTestError: Error {
    case failed
}

struct EmailCredentialStoreTests {
    @Test func addsUpdatesAndDeletesCredential() throws {
        let backend = MemoryEmailCredentialBackend()
        let store = EmailCredentialStore(backend: backend)
        let id = UUID()

        try store.save("first-secret", accountID: id)
        #expect(store.load(accountID: id) == "first-secret")
        try store.save("second-secret", accountID: id)
        #expect(store.load(accountID: id) == "second-secret")
        try store.delete(accountID: id)
        #expect(store.load(accountID: id) == nil)
    }

    @Test func failedSaveLeavesNoCredential() {
        let backend = MemoryEmailCredentialBackend()
        backend.failSave = true
        let store = EmailCredentialStore(backend: backend)
        let id = UUID()

        #expect(throws: CredentialBackendTestError.self) {
            try store.save("secret", accountID: id)
        }
        #expect(store.load(accountID: id) == nil)
    }
}
