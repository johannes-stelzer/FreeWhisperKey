import Foundation

enum LaunchAtLoginError: LocalizedError {
    case executableUnavailable

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "Unable to locate the FreeWhisperKey executable."
        }
    }
}

final class LaunchAtLoginController {
    private let fileManager: FileManager
    private let bundle: Bundle
    private let label: String

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.label = bundle.bundleIdentifier ?? "com.freewhisperkey.FreeWhisperKey"
    }

    private var launchAgentsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var agentURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: agentURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try createLaunchAgentFile()
        } else {
            try removeLaunchAgentFileIfNeeded()
        }
    }

    private func createLaunchAgentFile() throws {
        guard let executableURL = bundle.executableURL else {
            throw LaunchAtLoginError.executableUnavailable
        }

        let directory = launchAgentsDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let plist: [String: Any] = [
            "Label": label,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProgramArguments": [executableURL.path]
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: [.atomic])
    }

    private func removeLaunchAgentFileIfNeeded() throws {
        guard fileManager.fileExists(atPath: agentURL.path) else { return }
        try fileManager.removeItem(at: agentURL)
    }
}
