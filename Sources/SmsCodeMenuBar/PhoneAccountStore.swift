import Carbon
import Foundation
import SmsCodeCore

final class PhoneAccountStore {
    private let defaults: UserDefaults
    private let key = "phoneAccounts.v21"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PhoneAccountList {
        guard let data = defaults.data(forKey: key) else {
            return PhoneAccountList()
        }

        do {
            return try JSONDecoder().decode(PhoneAccountList.self, from: data)
        } catch {
            return PhoneAccountList()
        }
    }

    func save(_ accountList: PhoneAccountList) {
        do {
            let data = try JSONEncoder().encode(accountList)
            defaults.set(data, forKey: key)
        } catch {
            defaults.removeObject(forKey: key)
        }
    }

    static func defaultShortcut(index: Int) -> KeyboardShortcutDescriptor {
        let boundedIndex = min(max(index, 1), 9)
        let keyCodes: [Int: Int] = [
            1: kVK_ANSI_1,
            2: kVK_ANSI_2,
            3: kVK_ANSI_3,
            4: kVK_ANSI_4,
            5: kVK_ANSI_5,
            6: kVK_ANSI_6,
            7: kVK_ANSI_7,
            8: kVK_ANSI_8,
            9: kVK_ANSI_9
        ]

        return KeyboardShortcutDescriptor(
            keyCode: UInt32(keyCodes[boundedIndex] ?? kVK_ANSI_1),
            modifierFlags: UInt32(optionKey | cmdKey),
            displayName: "⌥⌘\(boundedIndex)"
        )
    }
}
