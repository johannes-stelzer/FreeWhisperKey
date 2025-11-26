import Foundation

enum SecureTemporaryDirectory {
    static func make(prefix: String, fileManager: FileManager = .default) throws -> URL {
        let identifier = UUID().uuidString
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent("\(prefix)-\(identifier)", isDirectory: true)
        try ensureDirectoryExists(at: directoryURL, fileManager: fileManager)
        try markExcludedFromBackup(directoryURL)
        return directoryURL
    }

    static func ensureDirectoryExists(at url: URL, fileManager: FileManager = .default) throws {
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o700))
        ]
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    static func markExcludedFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }
}
