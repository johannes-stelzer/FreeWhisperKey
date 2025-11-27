import Foundation

public struct TemporaryRecording: Sendable {
    public let url: URL
    private let directoryURL: URL
    private let secureOverwrite: Bool

    public init(prefix: String = "recording", fileExtension: String = "wav", secureOverwrite: Bool = true, fileManager: FileManager = .default) throws {
        self.secureOverwrite = secureOverwrite

        let identifier = UUID().uuidString
        directoryURL = fileManager.temporaryDirectory.appendingPathComponent("freewhisperkey-recording-\(identifier)", isDirectory: true)
        try SecureTemporaryDirectory.ensureDirectoryExists(at: directoryURL, fileManager: fileManager)
        try SecureTemporaryDirectory.markExcludedFromBackup(directoryURL)
        url = directoryURL.appendingPathComponent("\(prefix)-\(identifier).\(fileExtension)")
        let created = fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )
        guard created else {
            throw TranscriptionError.recorderFailed("Unable to create secure recording file at \(url.path).")
        }
    }

    public func cleanup(fileManager: FileManager = .default) throws {
        var firstError: Error?

        if secureOverwrite {
            do {
                try SecureFileEraser.zeroOutFile(at: url, fileManager: fileManager)
            } catch {
                firstError = error
            }
        }

        do {
            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }
        } catch {
            firstError = firstError ?? error
        }

        if let error = firstError {
            throw TranscriptionError.cleanupFailed("Temporary recording cleanup failed: \(error.localizedDescription)")
        }
    }
}
