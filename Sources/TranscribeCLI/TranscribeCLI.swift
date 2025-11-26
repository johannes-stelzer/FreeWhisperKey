import Foundation
import TranscriptionCore

@main
struct TranscribeCLI {
    static func main() {
        do {
            let recorder = MicRecorder()
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mic-\(UUID().uuidString).wav")
            print("Recording 5 seconds of audio... (grant microphone access if prompted)")
            try recorder.record(into: audioURL, duration: 5)
            print("Recording saved to \(audioURL.path)")

            let bundle = try WhisperBundleResolver.resolve()
            let bridge = WhisperBridge(executableURL: bundle.binary, modelURL: bundle.defaultModel)
            print("Running whisper-cli...")
            let transcript = try bridge.transcribe(audioURL: audioURL)
            let delivery = TranscriptDelivery()
            let config = TranscriptDeliveryConfiguration(
                autoPasteEnabled: false,
                prependSpaceBeforePaste: false,
                insertNewlineOnBreak: true
            )
            if let result = delivery.processTranscript(transcript, configuration: config) {
                print("\nTranscription:\n\(result.normalizedText)\n")
            } else {
                print("\nTranscription:\n\(transcript)\n")
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
