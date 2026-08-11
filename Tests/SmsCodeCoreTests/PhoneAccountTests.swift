import Foundation
import Testing
@testable import SmsCodeCore

struct PhoneAccountTests {
    @Test func upsertAddsAndReplacesAccountWithoutPhoneNumber() throws {
        let shortcut = KeyboardShortcutDescriptor(keyCode: 18, modifierFlags: 256, displayName: "⌥⌘1")
        let id = UUID()
        var list = PhoneAccountList()

        list.upsert(PhoneAccount(id: id, name: "主号", shortcut: shortcut))
        list.upsert(PhoneAccount(id: id, name: "工作号", shortcut: shortcut, isEnabled: false))

        #expect(list.accounts.count == 1)
        #expect(list.accounts[0].name == "工作号")
        #expect(list.enabledAccounts.isEmpty)

        let data = try JSONEncoder().encode(list)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("138"))
        #expect(json.contains("工作号"))
    }

    @Test func removesAccountByID() {
        let shortcut = KeyboardShortcutDescriptor(keyCode: 18, modifierFlags: 256, displayName: "⌥⌘1")
        let id = UUID()
        var list = PhoneAccountList(accounts: [
            PhoneAccount(id: id, name: "主号", shortcut: shortcut)
        ])

        list.remove(id: id)

        #expect(list.accounts.isEmpty)
    }
}
