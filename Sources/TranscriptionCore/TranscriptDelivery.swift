import Foundation

public struct TranscriptDeliveryConfiguration: Sendable {
    public var autoPasteEnabled: Bool
    public var prependSpaceBeforePaste: Bool
    public var insertNewlineOnBreak: Bool

    public init(autoPasteEnabled: Bool, prependSpaceBeforePaste: Bool, insertNewlineOnBreak: Bool) {
        self.autoPasteEnabled = autoPasteEnabled
        self.prependSpaceBeforePaste = prependSpaceBeforePaste
        self.insertNewlineOnBreak = insertNewlineOnBreak
    }
}

public struct TranscriptDeliveryResult: Sendable {
    public enum Action: Sendable {
        case paste(String)
        case copy(String)
    }

    public let normalizedText: String
    public let action: Action

    public init(normalizedText: String, action: Action) {
        self.normalizedText = normalizedText
        self.action = action
    }
}

public final class TranscriptDelivery: @unchecked Sendable {
    public private(set) var lastTranscript: String?
    private var lastPasteDate: Date?
    private let pasteBreakInterval: TimeInterval
    private let clock: () -> Date

    public init(pasteBreakInterval: TimeInterval = 6, clock: @escaping () -> Date = Date.init) {
        self.pasteBreakInterval = pasteBreakInterval
        self.clock = clock
    }

    public func processTranscript(_ text: String, configuration: TranscriptDeliveryConfiguration) -> TranscriptDeliveryResult? {
        let normalized = normalize(text, configuration: configuration)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "[BLANK_AUDIO]" else { return nil }
        lastTranscript = normalized

        if configuration.autoPasteEnabled {
            let outgoing = preparedTranscriptForPasting(original: normalized, trimmed: trimmed, configuration: configuration)
            return TranscriptDeliveryResult(normalizedText: normalized, action: .paste(outgoing))
        } else {
            return TranscriptDeliveryResult(normalizedText: normalized, action: .copy(normalized))
        }
    }

    public func markPasteCompleted() {
        lastPasteDate = clock()
    }

    public func resetPasteHistory() {
        lastPasteDate = nil
    }

    private func normalize(_ text: String, configuration: TranscriptDeliveryConfiguration) -> String {
        guard !configuration.insertNewlineOnBreak else { return text }
        let newlineSet = CharacterSet.newlines
        let segments = text.components(separatedBy: newlineSet)
        let joined = segments.joined(separator: " ")
        return joined.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    private func preparedTranscriptForPasting(original: String, trimmed: String, configuration: TranscriptDeliveryConfiguration) -> String {
        guard !original.isEmpty else { return original }
        var prefix = ""
        if configuration.insertNewlineOnBreak,
           shouldInsertBreakBeforePaste(),
           !trimmed.isEmpty,
           !original.hasPrefix("\n") {
            prefix.append("\n")
        }
        if configuration.prependSpaceBeforePaste,
           !trimmed.isEmpty,
           !startsWithLeadingWhitespace(original) {
            prefix.append(" ")
        }
        return prefix.isEmpty ? original : prefix + original
    }

    private func shouldInsertBreakBeforePaste() -> Bool {
        guard let lastPasteDate else { return false }
        return clock().timeIntervalSince(lastPasteDate) >= pasteBreakInterval
    }

    private func startsWithLeadingWhitespace(_ text: String) -> Bool {
        guard let firstScalar = text.unicodeScalars.first else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(firstScalar)
    }
}
