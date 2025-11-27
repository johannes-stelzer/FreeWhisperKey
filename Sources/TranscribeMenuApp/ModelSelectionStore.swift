import Foundation
import OSLog
import TranscriptionCore

enum ModelSelectionError: LocalizedError {
    case noModelsAvailable(modelsDirectory: URL)

    var errorDescription: String? {
        switch self {
        case .noModelsAvailable(let directory):
            return "No Whisper models are installed. Download a ggml model into \(directory.path)."
        }
    }
}

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
        case .tiny:
            return 77_691_713
        case .tinyEn:
            return 77_704_715
        case .base:
            return 147_951_465
        case .baseEn:
            return 147_964_211
        case .small:
            return 487_601_967
        case .smallEn:
            return 487_614_201
        case .medium:
            return 1_533_763_059
        case .mediumEn:
            return 1_533_774_781
        case .largeV1, .largeV2:
            return 3_094_623_691
        case .largeV3:
            return 3_095_033_483
        }
    }

    var checksum: String {
        switch self {
        case .tiny:
            return "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
        case .tinyEn:
            return "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"
        case .base:
            return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .baseEn:
            return "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        case .small:
            return "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        case .smallEn:
            return "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
        case .medium:
            return "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        case .mediumEn:
            return "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"
        case .largeV1:
            return "7d99f41a10525d0206bddadd86760181fa920438b6b33237e3118ff6c83bb53d"
        case .largeV2:
            return "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487"
        case .largeV3:
            return "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        }
    }
}

struct ModelOption {
    enum Kind {
        case known(KnownModel)
        case local
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
    private let logger = Logger(subsystem: "com.freewhisperkey.app", category: "ModelSelection")
    private var pendingValidationIssue: String?

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
        pendingValidationIssue = nil

        if let fileName = settings.selectedModelFilename {
            let validator = ModelSelectionValidator(bundle: bundle, fileManager: fileManager)
            switch validator.validate(fileName: fileName) {
            case let .valid(url):
                return url
            case let .invalid(reason):
                let message = "Stored model \"\(fileName)\" was rejected: \(reason). Falling back to \(bundle.defaultModel.lastPathComponent)."
                pendingValidationIssue = message
                settings.selectedModelFilename = nil
                logger.warning("\(message, privacy: .public)")
                return try defaultModelURL(in: bundle)
            }
        }

        return try defaultModelURL(in: bundle)
    }

    private func defaultModelURL(in bundle: WhisperBundle) throws -> URL {
        let defaultURL = bundle.defaultModel
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: defaultURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            if settings.selectedModelFilename == nil {
                settings.selectedModelFilename = defaultURL.lastPathComponent
            }
            return defaultURL
        }
        throw ModelSelectionError.noModelsAvailable(modelsDirectory: bundle.modelsDirectory)
    }

    func applySelection(_ option: ModelOption) {
        settings.selectedModelFilename = option.fileName
    }

    func resetCustomModelIfNeeded(bundle: WhisperBundle) {
        guard settings.selectedModelFilename == nil else { return }
        let defaultURL = bundle.defaultModel
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: defaultURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            settings.selectedModelFilename = defaultURL.lastPathComponent
        }
    }

    func drainValidationIssueMessage() -> String? {
        defer { pendingValidationIssue = nil }
        return pendingValidationIssue
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

        return options
    }

    private func determineSelectionIndex(options: [ModelOption], bundle: WhisperBundle) -> Int? {
        guard !options.isEmpty else { return nil }

        if let fileName = settings.selectedModelFilename,
           let idx = options.firstIndex(where: { $0.fileName == fileName }) {
            return idx
        }

        if let idx = options.firstIndex(where: {
            if case let .known(known) = $0.kind {
                return known == .mediumEn
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
        if let fileName = settings.selectedModelFilename {
            return "Selected model: \(fileName)"
        }

        let defaultURL = bundle.defaultModel
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: defaultURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return "Selected model: \(defaultURL.lastPathComponent)"
        }

        return "No model selected. Download a ggml model to get started."
    }
}

private struct ModelSelectionValidator {
    enum Result {
        case valid(URL)
        case invalid(String)
    }

    let bundle: WhisperBundle
    let fileManager: FileManager

    func validate(fileName: String) -> Result {
        guard !fileName.isEmpty else {
            return .invalid("stored value was empty")
        }

        if fileName.contains("/") || fileName.contains("\\") {
            return .invalid("path separators are not allowed in model names")
        }

        let candidate = bundle.modelsDirectory.appendingPathComponent(fileName)
        guard candidate.isDescendant(of: bundle.modelsDirectory) else {
            return .invalid("path attempted to escape the models directory")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return .invalid("file does not exist at \(candidate.path)")
        }

        guard !isDirectory.boolValue else {
            return .invalid("selection points to a directory, not a model file")
        }

        return .valid(candidate)
    }
}

private extension URL {
    func isDescendant(of parent: URL) -> Bool {
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSelf = self.resolvingSymlinksInPath().standardizedFileURL
        var parentPath = resolvedParent.path
        if !parentPath.hasSuffix("/") {
            parentPath.append("/")
        }
        return resolvedSelf.path.hasPrefix(parentPath)
    }
}
