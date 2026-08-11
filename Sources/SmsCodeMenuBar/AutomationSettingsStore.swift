import Foundation
import SmsCodeCore

final class AutomationSettingsStore {
    private let defaults: UserDefaults
    private let key = "automationSettings.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AutomationSettings {
        guard let data = defaults.data(forKey: key) else {
            return AutomationSettings()
        }

        do {
            return try JSONDecoder().decode(AutomationSettings.self, from: data)
        } catch {
            return AutomationSettings()
        }
    }

    func save(_ settings: AutomationSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: key)
        } catch {
            defaults.removeObject(forKey: key)
        }
    }
}
