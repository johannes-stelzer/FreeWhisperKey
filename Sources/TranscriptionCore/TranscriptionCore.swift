import AVFoundation
import Foundation

public enum TranscriptionError: LocalizedError {
    case microphonePermissionDenied
    case recorderFailed(String)
    case bundleMissing(String)
    case whisperFailed(String)

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
        }
    }
}

public final class MicRecorder: NSObject, @unchecked Sendable {
    private var activeRecorder: AVAudioRecorder?

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
        guard recorder.record() else {
            throw TranscriptionError.recorderFailed("Unable to start recording.")
        }
        activeRecorder = recorder
    }

    public func stopRecording() {
        activeRecorder?.stop()
        activeRecorder = nil
    }

    public func record(into url: URL, duration: TimeInterval) throws {
        try beginRecording(into: url)
        let target = Date().addingTimeInterval(duration)
        while isRecording, Date() < target {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        stopRecording()
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
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(UUID().uuidString)")

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

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw TranscriptionError.whisperFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let transcriptURL = tempBase.appendingPathExtension("txt")
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
