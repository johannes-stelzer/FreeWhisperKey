import XCTest
@testable import TranscriptionCore

final class TemporaryRecordingTests: XCTestCase {
    func testTemporaryRecordingCreatesSecureDirectory() throws {
        let recording = try TemporaryRecording(prefix: "security-test")
        defer { try? recording.cleanup() }

        let directoryURL = recording.url.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700, "Temporary directory must be user-only readable.")

        let resourceValues = try directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true, "Temporary recordings should be excluded from backups.")

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: recording.url.path)
        let filePermissions = fileAttributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600, "Recording file must be user-only readable.")
    }

    func testCleanupRemovesDirectory() throws {
        let recording = try TemporaryRecording(prefix: "cleanup-test")
        let directoryURL = recording.url.deletingLastPathComponent()
        _ = FileManager.default.createFile(atPath: recording.url.path, contents: Data(), attributes: nil)

        XCTAssertNoThrow(try recording.cleanup())

        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
    }
}
