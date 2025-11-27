import CryptoKit
import Foundation

enum BundleIntegrity {
    struct Expectation {
        let path: String
        let sha256: String

        func url(relativeTo root: URL) -> URL {
            return root.appendingPathComponent(path)
        }
    }

    static func validate(_ expectation: Expectation, root: URL, fileManager: FileManager = .default) throws {
        let targetURL = expectation.url(relativeTo: root)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw TranscriptionError.bundleMissing("Integrity check failed. Missing file \(targetURL.path).")
        }

        let digest = try sha256(for: targetURL)
        guard digest == expectation.sha256 else {
            throw TranscriptionError.bundleMissing("Integrity check failed for \(targetURL.lastPathComponent). Expected \(expectation.sha256), got \(digest).")
        }
    }

    private static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            } else {
                break
            }
        }
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }
}
