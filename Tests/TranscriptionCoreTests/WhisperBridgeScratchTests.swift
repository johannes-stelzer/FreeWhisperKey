import XCTest
@testable import TranscriptionCore

final class WhisperBridgeScratchTests: XCTestCase {
    func testScratchDirectoryPermissions() throws {
        let scratch = try WhisperBridge.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let resourceValues = try scratch.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    }

    func testSecureCleanupRemovesDirectory() throws {
        let scratch = try WhisperBridge.makeScratchDirectory()
        let sampleFile = scratch.appendingPathComponent("transcript.txt")
        try Data(repeating: 0xBB, count: 512).write(to: sampleFile)

        try WhisperBridge.securelyRemoveScratchDirectory(at: scratch)

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }
}
