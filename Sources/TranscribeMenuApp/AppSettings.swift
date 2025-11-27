import Foundation
import TranscriptionCore

final class AppSettings {
    private enum Keys: String {
        case autoPasteEnabled
        case selectedModelFilename
        case prependSpaceBeforePaste
        case insertNewlineOnBreak
        case launchAtLoginEnabled
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoPasteEnabled.rawValue: true,
            Keys.prependSpaceBeforePaste.rawValue: true,
            Keys.launchAtLoginEnabled.rawValue: false
        ])
    }

    var autoPasteEnabled: Bool {
        get { bool(for: .autoPasteEnabled) }
        set { set(newValue, for: .autoPasteEnabled) }
    }

    var selectedModelFilename: String? {
        get { defaults.string(forKey: Keys.selectedModelFilename.rawValue) }
        set { defaults.set(newValue, forKey: Keys.selectedModelFilename.rawValue) }
    }

    var prependSpaceBeforePaste: Bool {
        get { bool(for: .prependSpaceBeforePaste) }
        set { set(newValue, for: .prependSpaceBeforePaste) }
    }

    var insertNewlineOnBreak: Bool {
        get { bool(for: .insertNewlineOnBreak) }
        set { set(newValue, for: .insertNewlineOnBreak) }
    }

    var launchAtLoginEnabled: Bool {
        get { bool(for: .launchAtLoginEnabled) }
        set { set(newValue, for: .launchAtLoginEnabled) }
    }

    // MARK: - Helpers

    private func bool(for key: Keys) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    private func set(_ value: Bool, for key: Keys) {
        defaults.set(value, forKey: key.rawValue)
    }

    var deliveryConfiguration: TranscriptDeliveryConfiguration {
        TranscriptDeliveryConfiguration(
            autoPasteEnabled: autoPasteEnabled,
            prependSpaceBeforePaste: prependSpaceBeforePaste,
            insertNewlineOnBreak: insertNewlineOnBreak
        )
    }
}
