import Foundation

enum SecureFileEraser {
    static func zeroOutFile(at url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let sizeValue = attributes[.size] as? NSNumber else { return }
        let length = sizeValue.uint64Value

        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "SecureFileEraser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open \(url.path) for wiping."])
        }

        defer { try? handle.close() }
        try handle.seek(toOffset: 0)

        let chunkSize = 64 * 1024
        let zeroChunk = Data(repeating: 0, count: chunkSize)
        var remaining = length

        while remaining > 0 {
            let toWrite = Int(min(UInt64(chunkSize), remaining))
            if toWrite == chunkSize {
                try handle.write(contentsOf: zeroChunk)
            } else if toWrite > 0 {
                try handle.write(contentsOf: Data(repeating: 0, count: toWrite))
            }
            remaining -= UInt64(toWrite)
        }

        try handle.synchronize()
    }

    static func enforceUserOnlyPermissions(for url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o600))
        ]
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
