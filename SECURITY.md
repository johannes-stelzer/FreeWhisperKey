# Security Notes

## Temporary Recording & Transcript Assets

- **Threat model** – The primary adversary is another local macOS user (including low-privileged malware) who can browse `/tmp` or user caches, plus automated backup tooling (Time Machine, cloud sync, Spotlight). Without hardening, raw microphone captures and Whisper transcripts left in temporary folders may be readable long after a session ends.
- **Mitigation** – `TemporaryRecording` and `WhisperBridge` now create their scratch directories with `0700` permissions, exclude them from backups, and zeroize file contents (`SecureFileEraser`) before deletion. Recording files are explicitly created and re-permissioned to `0600`, preventing other accounts from opening them even if they discover the path.
- **Residual risk** – While cleanup failures now bubble up (`TranscriptionError.cleanupFailed`), crashes or forced quits can still leave artifacts on disk; users should treat transcription sessions as sensitive operations and clear `/tmp` if they suspect an abrupt termination. Automatic pasting may expose transcripts to clipboard snoopers until later steps replace the current implementation.
