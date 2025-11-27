import XCTest
@testable import TranscribeMenuApp
@testable import TranscriptionCore

final class ModelSelectionStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var bundle: WhisperBundle!
    private var settings: AppSettings!
    private var store: ModelSelectionStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        suiteName = "ModelSelectionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        settings = AppSettings(defaults: defaults)

        tempRoot = fileManager.temporaryDirectory.appendingPathComponent("ModelSelectionStore-\(UUID().uuidString)", isDirectory: true)
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        let modelsDir = tempRoot.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let binary = binDir.appendingPathComponent("whisper-cli")
        fileManager.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])

        let defaultModel = modelsDir.appendingPathComponent("ggml-medium.en.bin")
        fileManager.createFile(atPath: defaultModel.path, contents: Data("base".utf8), attributes: nil)

        bundle = WhisperBundle(root: tempRoot, binary: binary, modelsDirectory: modelsDir, defaultModel: defaultModel)
        store = ModelSelectionStore(settings: settings, fileManager: fileManager)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        settings = nil
        store = nil
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try? fileManager.removeItem(at: tempRoot)
        }
    }

    func testAbsolutePathSelectionFallsBackToDefault() throws {
        settings.selectedModelFilename = "/etc/passwd"
        let resolved = try store.resolveModelURL(in: bundle)

        XCTAssertEqual(resolved, bundle.defaultModel)
        XCTAssertEqual(settings.selectedModelFilename, bundle.defaultModel.lastPathComponent)

        let warning = store.drainValidationIssueMessage()
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("path separators") ?? false)
    }

    func testMissingFileSelectionFallsBackToDefault() throws {
        settings.selectedModelFilename = "ghost.bin"

        let resolved = try store.resolveModelURL(in: bundle)
        XCTAssertEqual(resolved, bundle.defaultModel)
        XCTAssertEqual(settings.selectedModelFilename, bundle.defaultModel.lastPathComponent)

        let warning = store.drainValidationIssueMessage()
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("does not exist") ?? false)
    }

    func testTraversalSelectionFallsBackToDefault() throws {
        settings.selectedModelFilename = "../escape.bin"

        let resolved = try store.resolveModelURL(in: bundle)
        XCTAssertEqual(resolved, bundle.defaultModel)
        XCTAssertEqual(settings.selectedModelFilename, bundle.defaultModel.lastPathComponent)

        let warning = store.drainValidationIssueMessage()
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("path separators") ?? false)
    }

    func testValidSelectionUsesCustomModel() throws {
        let customName = "local-model.bin"
        let customURL = bundle.modelsDirectory.appendingPathComponent(customName)
        fileManager.createFile(atPath: customURL.path, contents: Data("custom".utf8), attributes: nil)

        settings.selectedModelFilename = customName
        let resolved = try store.resolveModelURL(in: bundle)

        XCTAssertEqual(resolved, customURL)
        XCTAssertNil(store.drainValidationIssueMessage())
    }

    func testThrowsWhenNoModelsArePresent() throws {
        try fileManager.removeItem(at: bundle.defaultModel)
        settings.selectedModelFilename = nil

        XCTAssertThrowsError(try store.resolveModelURL(in: bundle)) { error in
            guard case ModelSelectionError.noModelsAvailable(let directory) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(directory, bundle.modelsDirectory)
        }
    }
}
