import CryptoKit
import Foundation

struct ModelVerifier {
    static func verify(downloadedFile url: URL, for model: KnownModel, fileManager: FileManager = .default) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let expected = model.expectedBytes,
           let sizeNumber = attributes[.size] as? NSNumber {
            let actual = sizeNumber.int64Value
            guard actual == expected else {
                throw ModelVerificationError.sizeMismatch(expected: expected, actual: actual)
            }
        }

        let computedHash = try sha256(of: url)
        guard computedHash == model.checksum else {
            throw ModelVerificationError.checksumMismatch(expected: model.checksum, actual: computedHash)
        }
    }

    private static func sha256(of url: URL) throws -> String {
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
