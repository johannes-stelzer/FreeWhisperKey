import XCTest
@testable import TranscriptionCore

final class SecureFileEraserTests: XCTestCase {
    func testZeroOutFileOverwritesContents() throws {
        let tempDir = try SecureTemporaryDirectory.make(prefix: "eraser-test")
        let fileURL = tempDir.appendingPathComponent("payload.bin")
        try Data(repeating: 0xAA, count: 1024).write(to: fileURL)

        try SecureFileEraser.zeroOutFile(at: fileURL)
        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(Set(data), [0], "File should be zeroized before removal.")

        try FileManager.default.removeItem(at: tempDir)
    }

    func testEnforceUserOnlyPermissions() throws {
        let tempDir = try SecureTemporaryDirectory.make(prefix: "perm-test")
        let fileURL = tempDir.appendingPathComponent("recording.wav")
        try Data().write(to: fileURL)

        try SecureFileEraser.enforceUserOnlyPermissions(for: fileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permission = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permission, 0o600)

        try FileManager.default.removeItem(at: tempDir)
    }
}
