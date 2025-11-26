import Foundation
import TranscriptionCore

final class AppSettings {
    private enum Keys: String {
        case autoPasteEnabled
        case selectedModelFilename
        case customModelPath
        case prependSpaceBeforePaste
        case insertNewlineOnBreak
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoPasteEnabled.rawValue: true,
            Keys.prependSpaceBeforePaste.rawValue: true
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

    var customModelPath: String? {
        get { defaults.string(forKey: Keys.customModelPath.rawValue) }
        set {
            if let newValue = newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Keys.customModelPath.rawValue)
            } else {
                defaults.removeObject(forKey: Keys.customModelPath.rawValue)
            }
        }
    }

    var prependSpaceBeforePaste: Bool {
        get { bool(for: .prependSpaceBeforePaste) }
        set { set(newValue, for: .prependSpaceBeforePaste) }
    }

    var insertNewlineOnBreak: Bool {
        get { bool(for: .insertNewlineOnBreak) }
        set { set(newValue, for: .insertNewlineOnBreak) }
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
