import AVFoundation
import Foundation

public enum TranscriptionError: LocalizedError {
    case microphonePermissionDenied
    case recorderFailed(String)
    case bundleMissing(String)
    case whisperFailed(String)
    case cleanupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .recorderFailed(let message):
            return "Audio recording failed: \(message)"
        case .bundleMissing(let message):
            return "Bundle configuration error: \(message)"
        case .whisperFailed(let message):
            return "whisper-cli exited with error: \(message)"
        case .cleanupFailed(let message):
            return "Secure cleanup failed: \(message)"
        }
    }
}

public final class MicRecorder: NSObject, @unchecked Sendable {
    private var activeRecorder: AVAudioRecorder?
    private var meterTimer: DispatchSourceTimer?
    public var levelUpdateHandler: ((Float) -> Void)?

    public override init() {}

    public var isRecording: Bool {
        activeRecorder?.isRecording ?? false
    }

    public func beginRecording(into url: URL) throws {
        guard !isRecording else {
            throw TranscriptionError.recorderFailed("Recorder already in use.")
        }
        guard try Self.requestPermission() else {
            throw TranscriptionError.microphonePermissionDenied
        }

        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.prepareToRecord()
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw TranscriptionError.recorderFailed("Unable to start recording.")
        }
        do {
            try SecureFileEraser.enforceUserOnlyPermissions(for: url)
        } catch {
            recorder.stop()
            throw TranscriptionError.recorderFailed("Failed to harden recording file: \(error.localizedDescription)")
        }
        activeRecorder = recorder
        startMetering()
    }

    public func stopRecording() {
        activeRecorder?.stop()
        activeRecorder = nil
        stopMetering()
    }

    public func record(into url: URL, duration: TimeInterval) throws {
        try beginRecording(into: url)
        let target = Date().addingTimeInterval(duration)
        while isRecording, Date() < target {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        stopRecording()
    }

    deinit {
        stopMetering()
    }

    private func startMetering() {
        stopMetering()
        guard activeRecorder != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let recorder = self.activeRecorder else {
                self?.stopMetering()
                return
            }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            self.notifyLevel(Self.normalized(power: power))
        }
        meterTimer = timer
        timer.resume()
    }

    private func stopMetering() {
        meterTimer?.cancel()
        meterTimer = nil
        notifyLevel(0)
    }

    private func notifyLevel(_ level: Float) {
        guard let handler = levelUpdateHandler else { return }
        DispatchQueue.main.async {
            handler(level)
        }
    }

    private static func normalized(power: Float) -> Float {
        guard power.isFinite else { return 0 }
        let minDb: Float = -60
        if power <= minDb { return 0 }
        let clamped = min(0, power)
        return min(1, max(0, (clamped - minDb) / -minDb))
    }

    private static func requestPermission() throws -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            final class PermissionBox: @unchecked Sendable {
                var value: Bool = false
            }
            let semaphore = DispatchSemaphore(value: 0)
            let box = PermissionBox()
            AVCaptureDevice.requestAccess(for: .audio) { allow in
                box.value = allow
                semaphore.signal()
            }
            semaphore.wait()
            return box.value
        @unknown default:
            return false
        }
    }

    private static var settings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
    }
}

public struct WhisperBridge: Sendable {
    public let executableURL: URL
    public let modelURL: URL

    public init(executableURL: URL, modelURL: URL) {
        self.executableURL = executableURL
        self.modelURL = modelURL
    }

    public func transcribe(audioURL: URL) throws -> String {
        let fileManager = FileManager.default
        let scratchDirectory = try Self.makeScratchDirectory(fileManager: fileManager)
        let tempBase = scratchDirectory.appendingPathComponent("transcript")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-otxt",
            "-of", tempBase.path
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "unknown error"
                throw TranscriptionError.whisperFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let transcriptURL = tempBase.appendingPathExtension("txt")
            let text = try String(contentsOf: transcriptURL, encoding: .utf8)
            do {
                try Self.securelyRemoveScratchDirectory(at: scratchDirectory, fileManager: fileManager)
            } catch {
                throw TranscriptionError.cleanupFailed("Cleanup failed after successful transcription: \(error.localizedDescription)")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            do {
                try Self.securelyRemoveScratchDirectory(at: scratchDirectory, fileManager: fileManager)
            } catch let cleanupError {
                let message = "Cleanup failed after error '\(error.localizedDescription)': \(cleanupError.localizedDescription)"
                throw TranscriptionError.cleanupFailed(message)
            }
            throw error
        }
    }

    static func makeScratchDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try SecureTemporaryDirectory.make(prefix: "whisper", fileManager: fileManager)
        return directory
    }

    static func securelyRemoveScratchDirectory(at url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var firstError: Error?
        func record(_ error: Error) {
            if firstError == nil {
                firstError = error
            }
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            contents = []
            record(error)
        }

        for entry in contents {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
            guard exists else { continue }
            if isDirectory.boolValue {
                do {
                    try securelyRemoveScratchDirectory(at: entry, fileManager: fileManager)
                } catch {
                    record(error)
                }
            } else {
                do {
                    try SecureFileEraser.zeroOutFile(at: entry, fileManager: fileManager)
                } catch {
                    record(error)
                }
                do {
                    try fileManager.removeItem(at: entry)
                } catch {
                    record(error)
                }
            }
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            record(error)
        }

        if let error = firstError {
            throw error
        }
    }
}

public struct WhisperBundle {
    public let root: URL
    public let binary: URL
    public let modelsDirectory: URL
    public let defaultModel: URL
}

public enum WhisperBundleResolver {
    public static func resolve(relativeTo directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> WhisperBundle {
        let bundleURL = directory.appendingPathComponent("dist/whisper-bundle")
        let binary = bundleURL.appendingPathComponent("bin/whisper-cli")
        let modelsDirectory = bundleURL.appendingPathComponent("models")
        let defaultModel = modelsDirectory.appendingPathComponent("ggml-base.bin")

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw TranscriptionError.bundleMissing("dist/whisper-bundle not found. Run scripts/package_whisper_bundle.sh first.")
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TranscriptionError.bundleMissing("whisper-cli binary missing or not executable at \(binary.path)")
        }
        guard FileManager.default.fileExists(atPath: defaultModel.path) else {
            throw TranscriptionError.bundleMissing("Model file missing at \(defaultModel.path)")
        }

        return WhisperBundle(root: bundleURL, binary: binary, modelsDirectory: modelsDirectory, defaultModel: defaultModel)
    }
}
