import AppKit
@preconcurrency import ApplicationServices
import Foundation
import TranscriptionCore

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let settings: AppSettings
    private let bundle: WhisperBundle
    private let modelSelectionStore: ModelSelectionStore
    private let onChange: () -> Void

    private var selectionSnapshot: ModelSelectionSnapshot?

    private let checkbox = NSButton(checkboxWithTitle: "Automatically paste transcript", target: nil, action: nil)
    private let prependSpaceCheckbox = NSButton(checkboxWithTitle: "Add a leading space before the pasted text", target: nil, action: nil)
    private let newlineOnBreakCheckbox = NSButton(checkboxWithTitle: "Start on a new line after a long pause", target: nil, action: nil)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPathField = NSTextField(labelWithString: "")
    private let downloadProgress = NSProgressIndicator()
    private let downloadStatusLabel = NSTextField(labelWithString: "")
    private var downloadDelegate: ModelDownloadDelegate?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadState: DownloadState = .idle {
        didSet { applyDownloadState() }
    }

    private enum DownloadState {
        case idle
        case inProgress(message: String, progress: Double?)
        case completed(String)
        case failed(String)

        var isActive: Bool {
            if case .inProgress = self { return true }
            return false
        }
    }

    private var isDownloading: Bool { downloadState.isActive }
    var isDownloadingModel: Bool { downloadState.isActive }

    init(settings: AppSettings, bundle: WhisperBundle, modelSelectionStore: ModelSelectionStore, onChange: @escaping () -> Void) {
        self.settings = settings
        self.bundle = bundle
        self.modelSelectionStore = modelSelectionStore
        self.onChange = onChange

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Preferences"
        window.center()
        super.init(window: window)

        checkbox.target = self
        checkbox.action = #selector(toggleAutoPaste)
        checkbox.state = settings.autoPasteEnabled ? .on : .off

        prependSpaceCheckbox.target = self
        prependSpaceCheckbox.action = #selector(togglePrependSpace)
        prependSpaceCheckbox.state = settings.prependSpaceBeforePaste ? .on : .off

        newlineOnBreakCheckbox.target = self
        newlineOnBreakCheckbox.action = #selector(toggleNewlineOnBreak)
        newlineOnBreakCheckbox.state = settings.insertNewlineOnBreak ? .on : .off

        modelPopup.target = self
        modelPopup.action = #selector(modelSelectionChanged)

        downloadProgress.style = .bar
        downloadProgress.controlSize = .small
        downloadProgress.isIndeterminate = true
        downloadProgress.isDisplayedWhenStopped = false
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 100
        downloadProgress.translatesAutoresizingMaskIntoConstraints = false
        downloadProgress.widthAnchor.constraint(equalToConstant: 180).isActive = true
        downloadProgress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        downloadProgress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        downloadStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        downloadStatusLabel.textColor = .secondaryLabelColor

        modelPathField.lineBreakMode = .byTruncatingMiddle
        modelPathField.textColor = .secondaryLabelColor

        refreshModelOptions()
        applyDownloadState()

        let behaviorHeader = PreferencesWindowController.makeHeader("Behavior")
        let behaviorDescription = PreferencesWindowController.makeSubtext("When automatic pasting is off, FreeWhisperKey copies the transcript to the clipboard instead.")

        let modelHeader = PreferencesWindowController.makeHeader("Model")
        let modelDescription = PreferencesWindowController.makeSubtext("Select a bundled ggml model. Missing models can be downloaded automatically.")

        let downloadStack = NSStackView(views: [downloadProgress, downloadStatusLabel])
        downloadStack.orientation = .vertical
        downloadStack.spacing = 4

        let modelStack = NSStackView(views: [
            modelPopup,
            modelDescription,
            modelPathField,
            downloadStack
        ])
        modelStack.orientation = .vertical
        modelStack.spacing = 8

        let stack = NSStackView(views: [
            behaviorHeader,
            checkbox,
            behaviorDescription,
            prependSpaceCheckbox,
            newlineOnBreakCheckbox,
            PreferencesWindowController.makeDivider(),
            modelHeader,
            modelStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        updateBehaviorControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleAutoPaste() {
        settings.autoPasteEnabled = (checkbox.state == .on)
        updateBehaviorControls()
        onChange()
    }

    @objc private func togglePrependSpace() {
        settings.prependSpaceBeforePaste = (prependSpaceCheckbox.state == .on)
        onChange()
    }

    @objc private func toggleNewlineOnBreak() {
        settings.insertNewlineOnBreak = (newlineOnBreakCheckbox.state == .on)
        onChange()
    }

    private func updateBehaviorControls() {
        prependSpaceCheckbox.isEnabled = settings.autoPasteEnabled
        prependSpaceCheckbox.alphaValue = settings.autoPasteEnabled ? 1 : 0.6
        newlineOnBreakCheckbox.isEnabled = settings.autoPasteEnabled
        newlineOnBreakCheckbox.alphaValue = settings.autoPasteEnabled ? 1 : 0.6
    }

    private func applyDownloadState() {
        let hasOptions = selectionSnapshot?.options.isEmpty == false
        switch downloadState {
        case .idle:
            downloadProgress.stopAnimation(nil)
            downloadProgress.isIndeterminate = true
            downloadProgress.doubleValue = 0
            downloadStatusLabel.stringValue = ""
            modelPopup.isEnabled = hasOptions
        case let .inProgress(message, progress):
            downloadStatusLabel.stringValue = message
            modelPopup.isEnabled = false
            if let progress {
                downloadProgress.isIndeterminate = false
                downloadProgress.doubleValue = progress * 100
            } else {
                if !downloadProgress.isIndeterminate {
                    downloadProgress.isIndeterminate = true
                }
                downloadProgress.startAnimation(nil)
            }
        case let .completed(message):
            downloadProgress.stopAnimation(nil)
            downloadProgress.isIndeterminate = true
            downloadProgress.doubleValue = 0
            downloadStatusLabel.stringValue = message
            modelPopup.isEnabled = hasOptions
        case let .failed(message):
            downloadProgress.stopAnimation(nil)
            downloadProgress.isIndeterminate = true
            downloadProgress.doubleValue = 0
            downloadStatusLabel.stringValue = message
            modelPopup.isEnabled = hasOptions
        }
    }

    private func refreshModelOptions() {
        selectionSnapshot = modelSelectionStore.snapshot(for: bundle)
        let options = selectionSnapshot?.options ?? []
        modelPopup.removeAllItems()
        if options.isEmpty {
            modelPopup.addItem(withTitle: "No bundle models found")
            modelPopup.isEnabled = false
        } else {
            for option in options {
                modelPopup.addItem(withTitle: option.menuTitle)
            }
            modelPopup.isEnabled = !isDownloading
        }
        updateModelSelectionUI()
    }

    func downloadKnownModelIfNeeded(_ known: KnownModel) {
        refreshModelOptions()
        guard let snapshot = selectionSnapshot else { return }
        guard let option = snapshot.options.first(where: {
            if case let .known(candidate) = $0.kind {
                return candidate == known
            }
            return false
        }) else {
            return
        }
        guard option.needsDownload else { return }
        startDownload(for: known, successSelection: option)
    }

    private func currentModelOption() -> ModelOption? {
        guard let snapshot = selectionSnapshot else { return nil }
        let index = modelPopup.indexOfSelectedItem
        guard index >= 0, index < snapshot.options.count else { return nil }
        return snapshot.options[index]
    }

    private func updateModelSelectionUI() {
        guard let snapshot = selectionSnapshot else {
            modelPopup.selectItem(at: -1)
            modelPathField.stringValue = "Download a ggml model to get started."
            return
        }

        if let selectedIndex = snapshot.selectedIndex,
           selectedIndex < modelPopup.numberOfItems {
            modelPopup.selectItem(at: selectedIndex)
        } else if modelPopup.numberOfItems > 0 {
            modelPopup.selectItem(at: 0)
        } else {
            modelPopup.selectItem(at: -1)
        }

        modelPathField.stringValue = snapshot.pathDescription
    }

    @objc private func modelSelectionChanged() {
        guard let option = currentModelOption() else { return }
        switch option.kind {
        case let .known(known) where option.needsDownload:
            startDownload(for: known, successSelection: option)
            return
        default:
            modelSelectionStore.applySelection(option)
            refreshModelOptions()
            onChange()
        }
    }

    private func startDownload(for known: KnownModel, successSelection: ModelOption) {
        guard !isDownloading else { return }
        downloadState = .inProgress(message: "Downloading \(known.displayName)…", progress: nil)

        let destination = bundle.modelsDirectory.appendingPathComponent(known.fileName)

        let delegate = ModelDownloadDelegate()
        delegate.expectedBytes = known.expectedBytes
        downloadDelegate = delegate

        delegate.progressHandler = { [weak self] fraction in
            guard let self else { return }
            DispatchQueue.main.async {
                let progress = fraction > 0 ? fraction : nil
                self.downloadState = .inProgress(message: "Downloading \(known.displayName)…", progress: progress)
            }
        }

        delegate.completionHandler = { [weak self] result in
            guard let self else { return }
            let fail: (String) -> Void = { message in
                DispatchQueue.main.async {
                    self.downloadState = .failed("Download failed: \(message)")
                    self.showError("Download failed: \(message)")
                    self.downloadDelegate = nil
                    self.activeDownloadTask = nil
                }
            }

            switch result {
            case .failure(let error):
                fail(error.localizedDescription)
            case .success(let tempLocation):
                do {
                    let fm = FileManager.default
                    defer { try? fm.removeItem(at: tempLocation) }

                    let stagingFileName = ".tmp-\(UUID().uuidString)-\(known.fileName)"
                    let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(stagingFileName)
                    defer { try? fm.removeItem(at: stagingURL) }

                    if fm.fileExists(atPath: stagingURL.path) {
                        try fm.removeItem(at: stagingURL)
                    }

                    try fm.moveItem(at: tempLocation, to: stagingURL)
                    try ModelVerifier.verify(downloadedFile: stagingURL, for: known, fileManager: fm)

                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: stagingURL, backupItemName: nil, options: [])
                    } else {
                        try fm.moveItem(at: stagingURL, to: destination)
                    }
                } catch {
                    fail(error.localizedDescription)
                    return
                }

                DispatchQueue.main.async {
                    self.modelSelectionStore.applySelection(successSelection)
                    self.downloadState = .completed("Installed \(known.displayName).")
                    self.downloadDelegate = nil
                    self.activeDownloadTask = nil
                    self.refreshModelOptions()
                    self.onChange()
                }
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let request = URLRequest(url: known.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let task = session.downloadTask(with: request)
        if let expected = known.expectedBytes {
            task.countOfBytesClientExpectsToReceive = expected
        }
        activeDownloadTask = task
        task.resume()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Model Download"
        alert.informativeText = message
        alert.runModal()
    }

    private static func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private static func makeSubtext(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        return label
    }

    private static func makeDivider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

@MainActor
final class DictationShortcutAdvisor {
    private var hasPrompted = false

    func promptIfNeeded() {
        guard !hasPrompted, Self.isFnMappedToDictation else { return }
        hasPrompted = true

        let alert = NSAlert()
        alert.messageText = "Fn key is still reserved for Dictation"
        alert.informativeText = "macOS currently launches Dictation when you press Fn, which causes the “processing your voice” popup.\nDisable or reassign the Dictation shortcut (Keyboard → Dictation → Shortcut) so FreeWhisperKey can use Fn uninterrupted."
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openKeyboardSettings()
        }
    }

    private static var isFnMappedToDictation: Bool {
        // Apple stores the fn-key behavior in com.apple.HIToolbox / AppleFnUsageType.
        // Empirically, value 3 corresponds to “Start Dictation”.
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox") else {
            return false
        }
        return defaults.integer(forKey: "AppleFnUsageType") == 3
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct AccessibilityPermissionAdvisor {
    private static let defaultsKey = "AccessibilityPermissionAdvisorPrompted"

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestSystemPromptIfNeeded() {
        guard !isTrusted else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: defaultsKey) {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            defaults.set(true, forKey: defaultsKey)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum PasteError: LocalizedError {
    case accessibilityDenied
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is required to paste automatically. Enable it under System Settings → Privacy & Security → Accessibility."
        case .eventCreationFailed:
            return "Failed to create keyboard event for paste operation."
        }
    }
}

@MainActor
final class PasteController {
    private let keyCodeV: CGKeyCode = 9

    func paste(text: String) throws {
        guard AccessibilityPermissionAdvisor.isTrusted else {
            AccessibilityPermissionAdvisor.requestSystemPromptIfNeeded()
            throw PasteError.accessibilityDenied
        }

        let pasteboard = NSPasteboard.general
        let previousItems = snapshotPasteboardItems(pasteboard.pasteboardItems)
        let previousString = previousItems.isEmpty ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try sendPasteKeyStroke()

        restoreClipboard(previousItems: previousItems, fallbackString: previousString, on: pasteboard)
    }

    private func sendPasteKeyStroke() throws {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else {
            throw PasteError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    @MainActor
    private func restoreClipboard(previousItems: [NSPasteboardItem], fallbackString: String?, on pasteboard: NSPasteboard) {
        guard !previousItems.isEmpty || fallbackString != nil else { return }
        let delay = DispatchTime.now() + .milliseconds(30)
        DispatchQueue.main.asyncAfter(deadline: delay) {
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            } else if let fallbackString {
                pasteboard.setString(fallbackString, forType: .string)
            }
        }
    }

    private func snapshotPasteboardItems(_ items: [NSPasteboardItem]?) -> [NSPasteboardItem] {
        guard let items, !items.isEmpty else { return [] }
        return items.map { original in
            let clone = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }
    }
}

final class FnHotkeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isFnDown = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handle(event)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let fnActive = event.modifierFlags.contains(.function)
        if fnActive && !isFnDown {
            isFnDown = true
            onPress?()
        } else if !fnActive && isFnDown {
            isFnDown = false
            onRelease?()
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isFnDown = false
    }

    deinit {
        stop()
    }
}


final class StatusIconView: NSView {
    enum State {
        case idle
        case recording
        case processing
    }

    var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            updateAnimationTimer()
            needsDisplay = true
            if state != .recording {
                recordingLevel = 0
            }
        }
    }

    private var recordingLevel: CGFloat = 0
    private var animationPhase: CGFloat = 0
    private var animationVelocity: CGFloat = 0
    private var animationTimer: DispatchSourceTimer?

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationTimer()
    }

    deinit {
        animationTimer?.cancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .idle:
            drawIdle(in: dirtyRect)
        case .recording:
            drawRecording(in: dirtyRect)
        case .processing:
            drawProcessing(in: dirtyRect)
        }
    }

    func updateRecordingLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        guard clamped != recordingLevel else { return }
        recordingLevel = clamped
        if state == .recording {
            needsDisplay = true
        }
    }

    private func drawIdle(in rect: NSRect) {
        _ = drawMicSymbol(in: rect, intensity: 1)
    }

    private func drawRecording(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: 2.6, dy: 2.6)
        let center = CGPoint(x: square.midX, y: square.midY)
        let maxRadius = min(square.width, square.height) / 2
        let rawLevel = max(0, min(1, recordingLevel))
        let emphasizedLevel = pow(rawLevel, 0.45)
        let intensity = max(0.05, min(1, emphasizedLevel * 1.1))
        let swell = 0.5 + 0.5 * sin(animationPhase * 1.5)

        let baseStrokeColor = NSColor.systemRed.withAlphaComponent(0.9)
        let softFillColor = NSColor.systemRed.withAlphaComponent(0.15 + 0.6 * intensity)

        // Outer breathing ring keeps everything centered and small.
        let outerRadius = min(maxRadius - 1.2, maxRadius * (0.62 + 0.25 * swell + 0.28 * intensity))
        let outerPath = NSBezierPath(ovalIn: CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        outerPath.lineWidth = 1.3
        baseStrokeColor.setStroke()
        outerPath.stroke()

        // Fill inner core.
        let coreRadius = outerRadius * (0.35 + 0.5 * intensity)
        let coreRect = CGRect(
            x: center.x - coreRadius,
            y: center.y - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        )
        softFillColor.setFill()
        NSBezierPath(ovalIn: coreRect).fill()

        // Tall capsule to hint at a mic stem, keeps design symmetric.
        let capsuleHeight = coreRadius * (1.1 + 0.4 * swell + 0.2 * intensity)
        let capsuleWidth = coreRadius * (0.45 + 0.4 * intensity)
        let capsuleRect = CGRect(
            x: center.x - capsuleWidth / 2,
            y: center.y - capsuleHeight / 2,
            width: capsuleWidth,
            height: capsuleHeight
        )
        let capsulePath = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleWidth / 2, yRadius: capsuleWidth / 2)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        capsulePath.lineWidth = 1
        capsulePath.stroke()

        // Symmetric opening wave arcs on top & bottom, animated by amplitude.
        let openingAngle = 28 + intensity * 90
        let waveLayers = 4
        for layer in 0..<waveLayers {
            let progress = CGFloat(layer) / CGFloat(waveLayers)
            let rawRadius = coreRadius + 4 + progress * (maxRadius * 0.8 - coreRadius)
            let radius = min(rawRadius, maxRadius - 1.5)
            let alpha = (0.3 - progress * 0.18) * (0.65 + 0.45 * intensity)
            let thickness = 0.9 + (1 - progress) * (0.9 + 0.4 * intensity)
            let currentOpening = openingAngle + CGFloat(layer) * (8 + intensity * 6) + intensity * 28
            let start = -currentOpening
            let end = currentOpening
            let rotationFactor = 0.1 + intensity * 0.6
            let phaseShift = animationPhase * rotationFactor + CGFloat(layer) * 0.08

            for offset in [CGFloat.pi / 2, -CGFloat.pi / 2] {
                let arcPath = NSBezierPath()
                arcPath.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: start + phaseShift * 60 + offset * 180 / .pi,
                    endAngle: end + phaseShift * 60 + offset * 180 / .pi,
                    clockwise: offset < 0
                )
                arcPath.lineWidth = thickness
                NSColor.white.withAlphaComponent(alpha).setStroke()
                arcPath.stroke()
            }
        }
    }

    private func drawProcessing(in rect: NSRect) {
        let metrics = drawMicSymbol(in: rect, intensity: 0.55)
        let center = metrics.center
        let orbitRadius = min(metrics.orbitRadius + 3, metrics.maxRadius - 1.5)

        let trackRect = CGRect(
            x: center.x - orbitRadius,
            y: center.y - orbitRadius,
            width: orbitRadius * 2,
            height: orbitRadius * 2
        )
        let trackPath = NSBezierPath(ovalIn: trackRect)
        trackPath.lineWidth = 0.8
        NSColor.systemGreen.withAlphaComponent(0.15).setStroke()
        trackPath.stroke()

        let dotRadius: CGFloat = 2.1
        let baseAngle = animationPhase * 1.6
        let angles: [CGFloat] = [baseAngle, -baseAngle + .pi]

        for adjustedAngle in angles {
            let position = CGPoint(
                x: center.x + cos(adjustedAngle) * orbitRadius,
                y: center.y + sin(adjustedAngle) * orbitRadius
            )

            let arcSweep: CGFloat = 50
            let startAngle = adjustedAngle * 180 / .pi - arcSweep / 2
            let arcPath = NSBezierPath()
            arcPath.appendArc(
                withCenter: center,
                radius: orbitRadius,
                startAngle: startAngle,
                endAngle: startAngle + arcSweep,
                clockwise: false
            )
            arcPath.lineWidth = 0.9
            NSColor.systemGreen.withAlphaComponent(0.18).setStroke()
            arcPath.stroke()

            let dotRect = CGRect(
                x: position.x - dotRadius,
                y: position.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            NSColor.systemGreen.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    @discardableResult
    private func drawMicSymbol(in rect: NSRect, intensity rawIntensity: CGFloat) -> (center: CGPoint, orbitRadius: CGFloat, maxRadius: CGFloat) {
        let intensity = max(0, min(1, rawIntensity))
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: 3, dy: 3)
        let center = CGPoint(x: square.midX, y: square.midY)
        let maxRadius = min(square.width, square.height) / 2

        let outerRadius = maxRadius * 0.8
        let outerPath = NSBezierPath(ovalIn: CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        NSColor.labelColor.withAlphaComponent(0.25 * intensity).setStroke()
        outerPath.lineWidth = 1
        outerPath.stroke()

        let innerRadius = outerRadius * 0.72
        let innerPath = NSBezierPath(ovalIn: CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        NSColor.labelColor.withAlphaComponent(0.08 * intensity).setFill()
        innerPath.fill()

        let capsuleWidth = innerRadius * 0.72
        let capsuleHeight = innerRadius * 1.25
        let capsuleRect = CGRect(
            x: center.x - capsuleWidth / 2,
            y: center.y - capsuleHeight / 2 + 1,
            width: capsuleWidth,
            height: capsuleHeight
        )
        let capsulePath = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleWidth / 2, yRadius: capsuleWidth / 2)
        NSColor.labelColor.withAlphaComponent(0.58 * intensity).setStroke()
        capsulePath.lineWidth = 1
        capsulePath.stroke()

        let stemHeight = capsuleHeight * 0.6
        let stemPath = NSBezierPath()
        stemPath.move(to: CGPoint(x: center.x, y: center.y - stemHeight / 2 - 1))
        stemPath.line(to: CGPoint(x: center.x, y: center.y - stemHeight))
        stemPath.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.6 * intensity).setStroke()
        stemPath.stroke()

        let baseWidth = capsuleWidth * 0.9
        let basePath = NSBezierPath()
        basePath.move(to: CGPoint(x: center.x - baseWidth / 2, y: center.y - stemHeight - 1.5))
        basePath.line(to: CGPoint(x: center.x + baseWidth / 2, y: center.y - stemHeight - 1.5))
        basePath.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.6 * intensity).setStroke()
        basePath.stroke()

        let waveRadius = innerRadius * 1
        for offset in [-1, 1] {
            let arcPath = NSBezierPath()
            arcPath.appendArc(
                withCenter: center,
                radius: waveRadius,
                startAngle: CGFloat(offset) * 35 - 90,
                endAngle: CGFloat(offset) * 65 - 90,
                clockwise: offset < 0
            )
            arcPath.lineWidth = 0.9
            NSColor.labelColor.withAlphaComponent(0.18 * intensity).setStroke()
            arcPath.stroke()
        }

        let highlightRadius = capsuleWidth * 0.3
        let highlightRect = CGRect(
            x: center.x - highlightRadius,
            y: center.y + capsuleHeight * 0.15 - highlightRadius,
            width: highlightRadius * 2,
            height: highlightRadius * 2
        )
        NSColor.labelColor.withAlphaComponent(0.1 * intensity).setFill()
        NSBezierPath(ovalIn: highlightRect).fill()

        return (center, outerRadius, maxRadius)
    }

    private func updateAnimationTimer() {
        let shouldAnimate: Bool
        switch state {
        case .idle:
            shouldAnimate = false
        case .recording, .processing:
            shouldAnimate = true
        }
        if shouldAnimate {
            startAnimationTimer()
        } else {
            stopAnimationTimer()
        }
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(48))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let speed: CGFloat
            switch self.state {
            case .idle:
                self.animationVelocity = 0
                speed = 0.08
            case .recording:
                let level = max(0, min(1, self.recordingLevel))
                let boosted = pow(level, 1.1)
                let targetSpeed: CGFloat = 0.012 + 0.35 * boosted
                self.animationVelocity += (targetSpeed - self.animationVelocity) * 0.15
                speed = self.animationVelocity
            case .processing:
                self.animationVelocity = 0.22
                speed = 0.22
            }
            self.animationPhase = (self.animationPhase + speed).truncatingRemainder(dividingBy: .pi * 2)
            self.needsDisplay = true
        }
        animationTimer = timer
        timer.resume()
    }

    private func stopAnimationTimer() {
        animationTimer?.cancel()
        animationTimer = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum CaptureState {
        case idle
        case starting(TemporaryRecording)
        case recording(TemporaryRecording)
        case processing
    }

    private var statusItem: NSStatusItem?
    private let statusIconView = StatusIconView()
    private let recorder = MicRecorder()
    private var whisperBundle: WhisperBundle?
    private var whisperBridge: WhisperBridge?
    private let workQueue = DispatchQueue(label: "com.freewhisperkey.menuapp")
    private let hotkeyMonitor = FnHotkeyMonitor()
    private let pasteController = PasteController()
    private let dictationAdvisor = DictationShortcutAdvisor()
    private let settings = AppSettings()
    private lazy var modelSelectionStore = ModelSelectionStore(settings: settings)
    private let transcriptDelivery = TranscriptDelivery()
    private var preferencesWindowController: PreferencesWindowController?
    private var hasShownModelInstallWarning = false
    private var state: CaptureState = .idle
    private var pendingStopAfterStart = false
    private var copyLastTranscriptItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        do {
            try configureBridge()
            configureHotkey()
            dictationAdvisor.promptIfNeeded()
            AccessibilityPermissionAdvisor.requestSystemPromptIfNeeded()
            recorder.levelUpdateHandler = { [weak self] level in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if case .recording = self.state {
                        self.statusIconView.updateRecordingLevel(CGFloat(level))
                    }
                }
            }
        } catch {
            presentAlert(message: error.localizedDescription, informativeText: "Menu app will quit.")
            NSApplication.shared.terminate(self)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = ""
            button.image = nil
            statusIconView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusIconView)
            NSLayoutConstraint.activate([
                statusIconView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                statusIconView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                statusIconView.topAnchor.constraint(equalTo: button.topAnchor),
                statusIconView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
        statusIconView.state = .idle
        let menu = NSMenu()

        let hintItem = NSMenuItem()
        hintItem.title = "Hold Fn to record, release to transcribe"
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let copyTranscriptItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
        copyTranscriptItem.target = self
        copyTranscriptItem.isEnabled = false
        copyLastTranscriptItem = copyTranscriptItem
        menu.addItem(copyTranscriptItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit FreeWhisperKey", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        updateCopyTranscriptMenuState()
    }

    private func configureBridge() throws {
        let bundle = try WhisperBundleResolver.resolve()
        whisperBundle = bundle
        do {
            whisperBridge = try buildBridge(using: bundle)
            hasShownModelInstallWarning = false
        } catch let selectionError as ModelSelectionError {
            whisperBridge = nil
            handleModelSelectionError(selectionError)
        }
    }

    private func buildBridge(using providedBundle: WhisperBundle? = nil) throws -> WhisperBridge {
        let bundle: WhisperBundle
        if let providedBundle {
            bundle = providedBundle
        } else if let cached = whisperBundle {
            bundle = cached
        } else {
            let resolved = try WhisperBundleResolver.resolve()
            whisperBundle = resolved
            bundle = resolved
        }

        let modelURL = try modelSelectionStore.resolveModelURL(in: bundle)
        if let warning = modelSelectionStore.drainValidationIssueMessage() {
            presentAlert(message: "Model Selection Reset", informativeText: warning)
        }
        return WhisperBridge(executableURL: bundle.binary, modelURL: modelURL)
    }

    private func reloadBridge() {
        do {
            whisperBridge = try buildBridge()
            hasShownModelInstallWarning = false
        } catch let selectionError as ModelSelectionError {
            whisperBridge = nil
            handleModelSelectionError(selectionError)
        } catch {
            presentAlert(message: "Model Error", informativeText: error.localizedDescription)
            if let bundle = whisperBundle {
                modelSelectionStore.resetCustomModelIfNeeded(bundle: bundle)
            }
            whisperBridge = try? buildBridge()
        }
    }

    private func handleModelSelectionError(_ error: ModelSelectionError) {
        promptForModelInstall(message: error.localizedDescription)
    }

    private func promptForModelInstall(message: String) {
        if !hasShownModelInstallWarning {
            presentAlert(message: "Install a Whisper model", informativeText: message)
            hasShownModelInstallWarning = true
        }
        openPreferences()
        preferencesWindowController?.downloadKnownModelIfNeeded(.mediumEn)
    }

    private func configureHotkey() {
        hotkeyMonitor.onPress = { [weak self] in self?.startPressToTalk() }
        hotkeyMonitor.onRelease = { [weak self] in self?.finishPressToTalk() }
        hotkeyMonitor.start()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }

    @objc private func openPreferences() {
        guard let bundle = whisperBundle else {
            presentAlert(message: "Bundle Error", informativeText: "Bundle not yet initialized.")
            return
        }
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                settings: settings,
                bundle: bundle,
                modelSelectionStore: modelSelectionStore
            ) { [weak self] in
                self?.reloadBridge()
            }
        }
        preferencesWindowController?.showWindow(self)
        preferencesWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startPressToTalk() {
        guard case .idle = state else { return }
        guard whisperBridge != nil else {
            promptForModelInstall(message: "Download a Whisper model in Preferences before transcribing.")
            return
        }

        let recording: TemporaryRecording
        do {
            recording = try TemporaryRecording(prefix: "ptt")
        } catch {
            presentAlert(message: "Recording Error", informativeText: "Unable to create a secure temporary file: \(error.localizedDescription)")
            return
        }

        state = .starting(recording)
        statusIconView.state = .processing
        pendingStopAfterStart = false

        recorder.beginRecording(into: recording.url) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    guard case .starting(let activeRecording) = self.state else {
                        return
                    }
                    self.state = .recording(activeRecording)
                    self.statusIconView.state = .recording
                    if self.pendingStopAfterStart {
                        self.pendingStopAfterStart = false
                        self.finishPressToTalk()
                    }
                case .failure(let error):
                    self.pendingStopAfterStart = false
                    self.cleanupRecording(recording, context: "failed to start recording")
                    self.state = .idle
                    self.statusIconView.state = .idle
                    self.presentAlert(message: "Recording Error", informativeText: error.localizedDescription)
                }
            }
        }
    }

    private func finishPressToTalk() {
        switch state {
        case .starting:
            pendingStopAfterStart = true
            return
        case .recording(let recording):
            pendingStopAfterStart = false
            recorder.stopRecording()
            state = .processing
            statusIconView.state = .processing
            transcribeRecording(recording)
        default:
            return
        }
    }

    private func transcribeRecording(_ recording: TemporaryRecording) {
        guard let bridge = whisperBridge else {
            cleanupRecording(recording, context: "bundle missing")
            promptForModelInstall(message: "Install a Whisper model before transcribing.")
            resetState()
            return
        }

        let activeBridge = bridge
        workQueue.async { [weak self] in
            let cleanupTask = {
                if let owner = self {
                    Task { @MainActor in
                        owner.cleanupRecording(recording, context: "transcription session")
                    }
                } else {
                    do {
                        try recording.cleanup()
                    } catch {
                        NSLog("Cleanup warning (background transcription): \(error.localizedDescription)")
                    }
                }
            }
            defer { cleanupTask() }
            guard let self else { return }
            do {
                let text = try activeBridge.transcribe(audioURL: recording.url)
                DispatchQueue.main.async {
                    self.presentTranscript(text)
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentProcessingError(error)
                }
            }
        }
    }

    private func presentTranscript(_ text: String) {
        resetState()
        guard let result = transcriptDelivery.processTranscript(text, configuration: settings.deliveryConfiguration) else {
            return
        }
        updateCopyTranscriptMenuState()
        switch result.action {
        case .paste(let outgoingText):
            do {
                try pasteController.paste(text: outgoingText)
                transcriptDelivery.markPasteCompleted()
            } catch let pasteError as PasteError {
                handlePasteError(pasteError)
            } catch {
                presentAlert(message: "Paste Error", informativeText: error.localizedDescription)
            }
        case .copy(let text):
            copyToClipboard(text)
            presentAlert(message: "Transcription Complete", informativeText: "Transcript copied to clipboard:\n\n\(text)")
        }
    }

    private func presentProcessingError(_ error: Error) {
        resetState()
        presentAlert(message: "Error", informativeText: error.localizedDescription)
    }

    private func handlePasteError(_ error: PasteError) {
        switch error {
        case .accessibilityDenied:
            AccessibilityPermissionAdvisor.requestSystemPromptIfNeeded()
            let alert = NSAlert()
            alert.messageText = "Allow Accessibility Control"
            alert.informativeText = error.localizedDescription + "\n\nFreeWhisperKey uses Accessibility access to paste transcripts automatically."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                AccessibilityPermissionAdvisor.openAccessibilitySettings()
            }
        case .eventCreationFailed:
            presentAlert(message: "Paste Error", informativeText: error.localizedDescription)
        }
    }

    private func resetState() {
        state = .idle
        pendingStopAfterStart = false
        statusIconView.state = .idle
    }

    private func presentAlert(message: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.runModal()
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func cleanupRecording(_ recording: TemporaryRecording, context: String) {
        do {
            try recording.cleanup()
        } catch {
            let details = "Failed to securely delete the recording (\(context)): \(error.localizedDescription)"
            DispatchQueue.main.async { [weak self] in
                self?.presentAlert(message: "Cleanup Error", informativeText: details)
            }
        }
    }

    @objc private func copyLastTranscript() {
        guard let transcript = transcriptDelivery.lastTranscript else { return }
        copyToClipboard(transcript)
    }

    private func updateCopyTranscriptMenuState() {
        copyLastTranscriptItem?.isEnabled = (transcriptDelivery.lastTranscript != nil)
    }
}
enum ModelVerificationError: LocalizedError {
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case let .checksumMismatch(expected, actual):
            return "Checksum mismatch. Expected \(expected), got \(actual)."
        case let .sizeMismatch(expected, actual):
            return "Model size mismatch. Expected \(expected) bytes, got \(actual) bytes."
        }
    }
}

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var progressHandler: ((Double) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?
    var expectedBytes: Int64?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let denominator: Double
        if totalBytesExpectedToWrite > 0 {
            denominator = Double(totalBytesExpectedToWrite)
        } else if let expectedBytes {
            denominator = Double(expectedBytes)
        } else {
            progressHandler?(0)
            return
        }
        let fraction = max(0, min(1, Double(totalBytesWritten) / denominator))
        progressHandler?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler?(.success(location))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completionHandler?(.failure(error))
        }
    }
}
