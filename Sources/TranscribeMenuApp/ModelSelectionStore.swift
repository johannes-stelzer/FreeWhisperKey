import Foundation
import TranscriptionCore

enum KnownModel: String, CaseIterable {
    case tiny = "tiny"
    case tinyEn = "tiny.en"
    case base = "base"
    case baseEn = "base.en"
    case small = "small"
    case smallEn = "small.en"
    case medium = "medium"
    case mediumEn = "medium.en"
    case largeV1 = "large-v1"
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .tinyEn: return "Tiny (English)"
        case .base: return "Base"
        case .baseEn: return "Base (English)"
        case .small: return "Small"
        case .smallEn: return "Small (English)"
        case .medium: return "Medium"
        case .mediumEn: return "Medium (English)"
        case .largeV1: return "Large v1"
        case .largeV2: return "Large v2"
        case .largeV3: return "Large v3"
        }
    }

    var fileName: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)?download=1")!
    }

    var expectedBytes: Int64? {
        switch self {
        case .tiny, .tinyEn:
            return 39_000_000
        case .base, .baseEn:
            return 141_000_000
        case .small, .smallEn:
            return 466_000_000
        case .medium, .mediumEn:
            return 1_553_000_000
        case .largeV1, .largeV2:
            return 2_884_000_000
        case .largeV3:
            return 3_088_000_000
        }
    }
}

struct ModelOption {
    enum Kind {
        case known(KnownModel)
        case local
        case custom
    }

    let kind: Kind
    let displayName: String
    let fileName: String?
    let available: Bool

    var menuTitle: String {
        available ? displayName : "\(displayName) (download)"
    }

    var needsDownload: Bool {
        if case .known = kind {
            return !available
        }
        return false
    }
}

struct ModelSelectionSnapshot {
    let options: [ModelOption]
    let selectedIndex: Int?
    let pathDescription: String

    var selectedOption: ModelOption? {
        guard let index = selectedIndex, options.indices.contains(index) else {
            return nil
        }
        return options[index]
    }
}

final class ModelSelectionStore {
    private let settings: AppSettings
    private let fileManager: FileManager

    init(settings: AppSettings, fileManager: FileManager = .default) {
        self.settings = settings
        self.fileManager = fileManager
    }

    func snapshot(for bundle: WhisperBundle) -> ModelSelectionSnapshot {
        let options = buildModelOptions(bundle: bundle)
        let selectedIndex = determineSelectionIndex(options: options, bundle: bundle)
        return ModelSelectionSnapshot(
            options: options,
            selectedIndex: selectedIndex,
            pathDescription: pathDescription(bundle: bundle)
        )
    }

    func resolveModelURL(in bundle: WhisperBundle) throws -> URL {
        if let customPath = settings.customModelPath {
            let url = URL(fileURLWithPath: customPath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw TranscriptionError.bundleMissing("Custom model not found at \(url.path).")
            }
            return url
        }

        if let fileName = settings.selectedModelFilename {
            let url = bundle.modelsDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: url.path) else {
                throw TranscriptionError.bundleMissing("Model not found at \(url.path).")
            }
            return url
        }

        return bundle.defaultModel
    }

    func applySelection(_ option: ModelOption) {
        switch option.kind {
        case .custom:
            break
        case .known, .local:
            settings.customModelPath = nil
            settings.selectedModelFilename = option.fileName
        }
    }

    func useCustomModel(at path: String) {
        settings.customModelPath = path
        settings.selectedModelFilename = nil
    }

    func resetCustomModelIfNeeded(defaultModelName: String) {
        settings.customModelPath = nil
        if settings.selectedModelFilename == nil {
            settings.selectedModelFilename = defaultModelName
        }
    }

    // MARK: - Helpers

    private func buildModelOptions(bundle: WhisperBundle) -> [ModelOption] {
        var options: [ModelOption] = []

        for known in KnownModel.allCases {
            let fileName = known.fileName
            let url = bundle.modelsDirectory.appendingPathComponent(fileName)
            let exists = fileManager.fileExists(atPath: url.path)
            options.append(ModelOption(
                kind: .known(known),
                displayName: known.displayName,
                fileName: fileName,
                available: exists
            ))
        }

        let knownNames = Set(options.compactMap { $0.fileName })
        if let contents = try? fileManager.contentsOfDirectory(at: bundle.modelsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "bin" {
                let fileName = url.lastPathComponent
                if !knownNames.contains(fileName) {
                    let title = "\(url.deletingPathExtension().lastPathComponent) (local)"
                    options.append(ModelOption(kind: .local, displayName: title, fileName: fileName, available: true))
                }
            }
        }

        if settings.customModelPath != nil {
            options.insert(ModelOption(kind: .custom, displayName: "Custom model", fileName: nil, available: true), at: 0)
        }

        return options
    }

    private func determineSelectionIndex(options: [ModelOption], bundle: WhisperBundle) -> Int? {
        guard !options.isEmpty else { return nil }

        if settings.customModelPath != nil,
           let idx = options.firstIndex(where: {
               if case .custom = $0.kind { return true }
               return false
           }) {
            return idx
        }

        if let fileName = settings.selectedModelFilename,
           let idx = options.firstIndex(where: { $0.fileName == fileName }) {
            return idx
        }

        if let idx = options.firstIndex(where: {
            if case let .known(known) = $0.kind {
                return known == .base
            }
            return false
        }) {
            settings.selectedModelFilename = options[idx].fileName
            return idx
        }

        if let idx = options.firstIndex(where: { $0.fileName != nil }) {
            settings.selectedModelFilename = options[idx].fileName
            return idx
        }

        return 0
    }

    private func pathDescription(bundle: WhisperBundle) -> String {
        if let customPath = settings.customModelPath {
            return "Custom model: \(customPath)"
        }

        if let fileName = settings.selectedModelFilename {
            let path = bundle.modelsDirectory.appendingPathComponent(fileName).path
            return "Bundle path: \(path)"
        }

        return "Bundle path: \(bundle.defaultModel.path)"
    }
}
