import AppKit
@preconcurrency import ApplicationServices
import Foundation
import TranscriptionCore
import UniformTypeIdentifiers

@MainActor private let accessibilityPromptOptionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

final class AppSettings {
    private enum Keys {
        static let autoPasteEnabled = "autoPasteEnabled"
        static let selectedModelFilename = "selectedModelFilename"
        static let customModelPath = "customModelPath"
    }

    private let defaults = UserDefaults.standard

    var autoPasteEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.autoPasteEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.autoPasteEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoPasteEnabled)
        }
    }

    var selectedModelFilename: String? {
        get { defaults.string(forKey: Keys.selectedModelFilename) }
        set { defaults.set(newValue, forKey: Keys.selectedModelFilename) }
    }

    var customModelPath: String? {
        get { defaults.string(forKey: Keys.customModelPath) }
        set {
            if let newValue = newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Keys.customModelPath)
            } else {
                defaults.removeObject(forKey: Keys.customModelPath)
            }
        }
    }
}

enum KnownModel: String, CaseIterable {
    case tiny = "tiny"
    case tinyEn = "tiny.en"
    case base = "base"
    case baseEn = "base.en"
    case small = "small"
    case smallEn = "small.en"
    case medium = "medium"
    case mediumEn = "medium.en"
    case largeV1 = "large-v1"
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .tinyEn: return "Tiny (English)"
        case .base: return "Base"
        case .baseEn: return "Base (English)"
        case .small: return "Small"
        case .smallEn: return "Small (English)"
        case .medium: return "Medium"
        case .mediumEn: return "Medium (English)"
        case .largeV1: return "Large v1"
        case .largeV2: return "Large v2"
        case .largeV3: return "Large v3"
        }
    }

    var fileName: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)?download=1")!
    }

    var expectedBytes: Int64? {
        switch self {
        case .tiny, .tinyEn:
            return 39_000_000
        case .base, .baseEn:
            return 141_000_000
        case .small, .smallEn:
            return 466_000_000
        case .medium, .mediumEn:
            return 1_553_000_000
        case .largeV1, .largeV2:
            return 2_884_000_000
        case .largeV3:
            return 3_088_000_000
        }
    }
}

struct ModelOption {
    enum Kind {
        case known(KnownModel)
        case local
        case custom
    }

    let kind: Kind
    let displayName: String
    let fileName: String?
    let available: Bool

    var menuTitle: String {
        available ? displayName : "\(displayName) (download)"
    }

    var needsDownload: Bool {
        if case .known = kind {
            return !available
        }
        return false
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

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let settings: AppSettings
    private let bundle: WhisperBundle
    private let onChange: () -> Void

    private var modelOptions: [ModelOption] = []

    private let checkbox = NSButton(checkboxWithTitle: "Automatically paste transcript at cursor", target: nil, action: nil)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPathField = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "Download Selected Model", target: nil, action: nil)
    private let downloadProgress = NSProgressIndicator()
    private let downloadStatusLabel = NSTextField(labelWithString: "")
    private var downloadDelegate: ModelDownloadDelegate?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var isDownloading = false

    init(settings: AppSettings, bundle: WhisperBundle, onChange: @escaping () -> Void) {
        self.settings = settings
        self.bundle = bundle
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

        modelPopup.target = self
        modelPopup.action = #selector(modelSelectionChanged)

        downloadButton.target = self
        downloadButton.action = #selector(downloadSelectedModel)

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

        let behaviorHeader = PreferencesWindowController.makeHeader("Behavior")
        let behaviorDescription = PreferencesWindowController.makeSubtext("When disabled, FreeWhisperKey copies the result to the clipboard instead of pasting.")

        let modelHeader = PreferencesWindowController.makeHeader("Model")
        let modelDescription = PreferencesWindowController.makeSubtext("Select a bundled ggml model or provide your own file.")

        let chooseButton = NSButton(title: "Use Custom Model…", target: self, action: #selector(chooseModel))
        let clearButton = NSButton(title: "Clear Custom Model", target: self, action: #selector(resetModel))

        let customButtons = NSStackView(views: [chooseButton, clearButton])
        customButtons.spacing = 8

        let downloadButtonRow = NSStackView(views: [downloadButton, downloadProgress])
        downloadButtonRow.spacing = 8

        let downloadStack = NSStackView(views: [downloadButtonRow, downloadStatusLabel])
        downloadStack.orientation = .vertical
        downloadStack.spacing = 4

        let modelStack = NSStackView(views: [
            modelPopup,
            modelDescription,
            modelPathField,
            downloadStack,
            customButtons
        ])
        modelStack.orientation = .vertical
        modelStack.spacing = 8

        let stack = NSStackView(views: [
            behaviorHeader,
            checkbox,
            behaviorDescription,
            PreferencesWindowController.makeDivider(),
            modelHeader,
            modelStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleAutoPaste() {
        settings.autoPasteEnabled = (checkbox.state == .on)
        onChange()
    }

    private func refreshModelOptions() {
        modelOptions = buildModelOptions()
        modelPopup.removeAllItems()
        if modelOptions.isEmpty {
            modelPopup.addItem(withTitle: "No bundle models found")
            modelPopup.isEnabled = false
        } else {
            for option in modelOptions {
                modelPopup.addItem(withTitle: option.menuTitle)
            }
            modelPopup.isEnabled = !isDownloading
        }
        updateModelSelectionUI()
    }

    private func buildModelOptions() -> [ModelOption] {
        var options: [ModelOption] = []
        let fm = FileManager.default

        for known in KnownModel.allCases {
            let fileName = known.fileName
            let exists = fm.fileExists(atPath: bundle.modelsDirectory.appendingPathComponent(fileName).path)
            options.append(ModelOption(kind: .known(known), displayName: known.displayName, fileName: fileName, available: exists))
        }

        let knownNames = Set(options.compactMap { $0.fileName })
        if let contents = try? fm.contentsOfDirectory(at: bundle.modelsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "bin" {
                let fileName = url.lastPathComponent
                if !knownNames.contains(fileName) {
                    let title = "\(url.deletingPathExtension().lastPathComponent) (local)"
                    options.append(ModelOption(kind: .local, displayName: title, fileName: fileName, available: true))
                }
            }
        }

        if settings.customModelPath != nil {
            options.insert(ModelOption(kind: .custom, displayName: "Custom model", fileName: nil, available: true), at: 0)
        }

        return options
    }

    private func currentModelOption() -> ModelOption? {
        let index = modelPopup.indexOfSelectedItem
        guard index >= 0, index < modelOptions.count else { return nil }
        return modelOptions[index]
    }

    private func updateModelSelectionUI() {
        defer {
            updateModelPathLabel()
            updateDownloadButtonState()
        }

        if settings.customModelPath != nil,
           let index = modelOptions.firstIndex(where: {
               if case .custom = $0.kind { return true }
               return false
           }) {
            modelPopup.selectItem(at: index)
            return
        }

        guard !modelOptions.isEmpty else {
            modelPathField.stringValue = "Add ggml models to dist/whisper-bundle/models."
            return
        }

        if let selected = settings.selectedModelFilename,
           let idx = modelOptions.firstIndex(where: { $0.fileName == selected }) {
            modelPopup.selectItem(at: idx)
        } else if let idx = modelOptions.firstIndex(where: {
            if case let .known(known) = $0.kind {
                return known == .base
            }
            return false
        }) {
            modelPopup.selectItem(at: idx)
            settings.selectedModelFilename = modelOptions[idx].fileName
        } else if let idx = modelOptions.firstIndex(where: { $0.fileName != nil }) {
            modelPopup.selectItem(at: idx)
            settings.selectedModelFilename = modelOptions[idx].fileName
        } else if !modelOptions.isEmpty {
            modelPopup.selectItem(at: 0)
        }
    }

    private func updateModelPathLabel() {
        if let customPath = settings.customModelPath {
            modelPathField.stringValue = "Custom model: \(customPath)"
            return
        }

        if let selected = settings.selectedModelFilename {
            let path = bundle.modelsDirectory.appendingPathComponent(selected).path
            modelPathField.stringValue = "Bundle path: \(path)"
            return
        }

        modelPathField.stringValue = "Bundle path: \(bundle.defaultModel.path)"
    }

    private func updateDownloadButtonState() {
        if let option = currentModelOption() {
            downloadButton.isEnabled = option.needsDownload && !isDownloading
        } else {
            downloadButton.isEnabled = false
        }
        if !isDownloading {
            downloadProgress.stopAnimation(nil)
            downloadStatusLabel.stringValue = ""
        }
    }

    @objc private func modelSelectionChanged() {
        guard let option = currentModelOption() else { return }
        switch option.kind {
        case .custom:
            break
        case let .known(known) where option.needsDownload:
            startDownload(for: known, successSelection: option)
            return
        default:
            settings.customModelPath = nil
            settings.selectedModelFilename = option.fileName
            onChange()
        }
        updateModelSelectionUI()
    }

    @objc private func chooseModel() {
        let panel = NSOpenPanel()
        if let binType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [binType]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Whisper Model (.bin)"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customModelPath = url.path
            settings.selectedModelFilename = nil
            refreshModelOptions()
            onChange()
        }
    }

    @objc private func resetModel() {
        settings.customModelPath = nil
        if settings.selectedModelFilename == nil {
            settings.selectedModelFilename = bundle.defaultModel.lastPathComponent
        }
        refreshModelOptions()
        onChange()
    }

    @objc private func downloadSelectedModel() {
        guard let option = currentModelOption(),
              case let .known(known) = option.kind else { return }
        startDownload(for: known, successSelection: option)
    }

    private func startDownload(for known: KnownModel, successSelection: ModelOption) {
        guard !isDownloading else { return }
        isDownloading = true
        modelPopup.isEnabled = false
        downloadButton.isEnabled = false
        downloadProgress.doubleValue = 0
        downloadProgress.isIndeterminate = true
        downloadProgress.startAnimation(nil)
        downloadStatusLabel.stringValue = "Downloading \(known.displayName)…"

        let destination = bundle.modelsDirectory.appendingPathComponent(known.fileName)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-model-\(UUID().uuidString).bin")

        let delegate = ModelDownloadDelegate()
        delegate.expectedBytes = known.expectedBytes
        downloadDelegate = delegate

        delegate.progressHandler = { [weak self] fraction in
            guard let self else { return }
            DispatchQueue.main.async {
                if fraction > 0 {
                    self.downloadProgress.isIndeterminate = false
                    self.downloadProgress.doubleValue = fraction * 100
                } else if !self.downloadProgress.isIndeterminate {
                    self.downloadProgress.isIndeterminate = true
                    self.downloadProgress.startAnimation(nil)
                }
            }
        }

        delegate.completionHandler = { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.downloadProgress.stopAnimation(nil)
                self.isDownloading = false
            }

            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.modelPopup.isEnabled = true
                    self.downloadStatusLabel.stringValue = ""
                    self.showError("Download failed: \(error.localizedDescription)")
                    self.downloadDelegate = nil
                    self.activeDownloadTask = nil
                    self.updateDownloadButtonState()
                }
            case .success(let tempLocation):
                do {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: tempURL.path) {
                        try fm.removeItem(at: tempURL)
                    }
                    try fm.moveItem(at: tempLocation, to: tempURL)
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.copyItem(at: tempURL, to: destination)
                    try fm.removeItem(at: tempURL)
                } catch {
                    DispatchQueue.main.async {
                        self.modelPopup.isEnabled = true
                        self.downloadStatusLabel.stringValue = ""
                        self.showError("Download failed: \(error.localizedDescription)")
                        self.downloadDelegate = nil
                        self.activeDownloadTask = nil
                        self.updateDownloadButtonState()
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.downloadStatusLabel.stringValue = "Installed \(known.displayName)."
                    self.modelPopup.isEnabled = true
                    self.downloadDelegate = nil
                    self.activeDownloadTask = nil
                    self.settings.customModelPath = nil
                    self.settings.selectedModelFilename = successSelection.fileName
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
        alert.informativeText = """
macOS currently launches Dictation when you press Fn, which causes the “processing your voice” popup.
Disable or reassign the Dictation shortcut (Keyboard → Dictation → Shortcut) so FreeWhisperKey can use Fn uninterrupted.
"""
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

final class PasteController {
    private let keyCodeV: CGKeyCode = 9

    func paste(text: String) throws {
        guard AXIsProcessTrustedWithOptions(nil) else {
            throw PasteError.accessibilityDenied
        }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        try sendPasteKeyStroke()

        if let previous = previousString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
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

final class TextCursorLocator {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private var didRequestAuthorizationPrompt = false

    @MainActor
    func requestAccessibilityAuthorizationIfNeeded() {
        guard !AXIsProcessTrusted(), !didRequestAuthorizationPrompt else { return }
        didRequestAuthorizationPrompt = true
        let options = [accessibilityPromptOptionKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func currentCaretPoint() -> CGPoint? {
        guard AXIsProcessTrusted() else { return nil }

        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusedResult == .success,
              let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }
        let targetElement = element as! AXUIElement

        var selectedRangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            targetElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard rangeResult == .success,
              let rangeAX = selectedRangeValue,
              CFGetTypeID(rangeAX) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = rangeAX as! AXValue

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }

        var insertionRange = CFRange(location: range.location + range.length, length: 0)
        guard let insertionAX = AXValueCreate(.cfRange, &insertionRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            targetElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            insertionAX,
            &boundsValue
        )
        guard boundsResult == .success,
              let boundsAX = boundsValue,
              CFGetTypeID(boundsAX) == AXValueGetTypeID() else {
            return nil
        }
        let boundsValueAX = boundsAX as! AXValue

        var rect = CGRect.zero
        guard AXValueGetType(boundsValueAX) == .cgRect,
              AXValueGetValue(boundsValueAX, .cgRect, &rect) else {
            return nil
        }

        return CGPoint(x: rect.midX, y: rect.midY)
    }
}

@MainActor
final class CursorLevelOverlay {
    private let overlaySize = CGSize(width: 44, height: 44)
    private let window: NSWindow
    private let levelView: CursorLevelView
    private var isVisible = false
    private var latestLevel: CGFloat = 0
    private var lastKnownPosition: CGPoint?
    private var hasShownWindow = false

    init() {
        levelView = CursorLevelView(frame: NSRect(origin: .zero, size: overlaySize))
        levelView.autoresizingMask = [.width, .height]

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: overlaySize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        window.contentView = levelView
        window.alphaValue = 0
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        hasShownWindow = false
        levelView.level = latestLevel
        if lastKnownPosition != nil {
            updatePosition()
            revealWindowIfNeeded()
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        hasShownWindow = false
        guard window.isVisible else {
            levelView.level = 0
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.window.orderOut(nil)
                self?.levelView.level = 0
            }
        }
    }

    func update(level: CGFloat, caretPoint: CGPoint?) {
        latestLevel = max(0, min(1, level))
        if let caretPoint {
            lastKnownPosition = caretPoint
        }
        guard isVisible else { return }
        levelView.level = latestLevel
        if lastKnownPosition != nil {
            updatePosition()
            revealWindowIfNeeded()
        }
    }

    func primeAnchor(with point: CGPoint?) {
        lastKnownPosition = point
        if isVisible, lastKnownPosition != nil {
            updatePosition()
            revealWindowIfNeeded()
        }
    }

    private func updatePosition() {
        guard let anchor = lastKnownPosition else { return }
        let origin = NSPoint(
            x: anchor.x - overlaySize.width / 2,
            y: anchor.y - overlaySize.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: overlaySize), display: false)
    }

    private func revealWindowIfNeeded() {
        guard isVisible, !hasShownWindow else { return }
        hasShownWindow = true
        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
    }
}

final class CursorLevelView: NSView {
    var level: CGFloat = 0 {
        didSet { targetLevel = max(0, min(1, level)) }
    }

    private var targetLevel: CGFloat = 0
    private var displayLevel: CGFloat = 0
    private var animationPhase: CGFloat = 0
    private var animationTimer: DispatchSourceTimer?

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    deinit {
        animationTimer?.cancel()
        animationTimer = nil
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.animationPhase = self.animationPhase.truncatingRemainder(dividingBy: .pi * 2) + 0.045
            let easing: CGFloat = 0.18
            self.displayLevel += (self.targetLevel - self.displayLevel) * easing
            self.needsDisplay = true
        }
        animationTimer = timer
        timer.resume()
    }

    private func stopAnimation() {
        animationTimer?.cancel()
        animationTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxRadius = min(bounds.width, bounds.height) / 2 - 1
        let activeLevel = displayLevel
        let pulse = 0.5 + 0.5 * sin(animationPhase * 2)

        let outerRect = NSRect(
            x: center.x - maxRadius,
            y: center.y - maxRadius,
            width: maxRadius * 2,
            height: maxRadius * 2
        )
        let baseAlpha = 0.08 + 0.2 * (activeLevel + pulse * 0.3)
        NSColor.white.withAlphaComponent(baseAlpha).setFill()
        NSBezierPath(ovalIn: outerRect).fill()

        let outerStroke = NSBezierPath(ovalIn: outerRect)
        outerStroke.lineWidth = 1
        NSColor.black.withAlphaComponent(0.45).setStroke()
        outerStroke.stroke()

        let arcRadius = maxRadius - 4
        let startAngle = (animationPhase * 180 / .pi).truncatingRemainder(dividingBy: 360)
        let sweep = (0.25 + 0.5 * activeLevel) * 320
        let endAngle = startAngle + sweep
        let arcWidth = 1.6 + activeLevel * 2.8

        let leadArc = NSBezierPath()
        leadArc.appendArc(withCenter: center, radius: arcRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        leadArc.lineWidth = arcWidth
        NSColor.white.withAlphaComponent(0.95).setStroke()
        leadArc.stroke()

        let shadowArc = NSBezierPath()
        shadowArc.appendArc(withCenter: center, radius: arcRadius - 3, startAngle: startAngle - 10, endAngle: endAngle - 10, clockwise: false)
        shadowArc.lineWidth = arcWidth * 0.7
        NSColor.black.withAlphaComponent(0.4).setStroke()
        shadowArc.stroke()

        let dashArc = NSBezierPath()
        dashArc.appendArc(withCenter: center, radius: arcRadius + 2, startAngle: startAngle + 6, endAngle: endAngle + 6, clockwise: false)
        dashArc.setLineDash([3, 4], count: 2, phase: animationPhase * 12)
        dashArc.lineWidth = 1
        NSColor.white.withAlphaComponent(0.35).setStroke()
        dashArc.stroke()

        let accentAngle = endAngle * .pi / 180
        let accentRadius = arcRadius
        let accentCenter = CGPoint(
            x: center.x + cos(accentAngle) * accentRadius,
            y: center.y + sin(accentAngle) * accentRadius
        )
        let accentSize = 3 + activeLevel * 3.2
        let accentRect = NSRect(
            x: accentCenter.x - accentSize / 2,
            y: accentCenter.y - accentSize / 2,
            width: accentSize,
            height: accentSize
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: accentRect).fill()
        let accentStroke = NSBezierPath(ovalIn: accentRect)
        accentStroke.lineWidth = 0.9
        NSColor.black.withAlphaComponent(0.5).setStroke()
        accentStroke.stroke()

        let coreRadius = (maxRadius - 10) * (0.4 + 0.45 * activeLevel)
        let coreRect = NSRect(
            x: center.x - coreRadius,
            y: center.y - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        )
        NSColor.white.withAlphaComponent(0.2 + 0.3 * activeLevel).setFill()
        NSBezierPath(ovalIn: coreRect).fill()
        let coreStroke = NSBezierPath(ovalIn: coreRect)
        coreStroke.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke()
        coreStroke.stroke()

        let crossLength = coreRadius * 0.55
        let crossPath = NSBezierPath()
        crossPath.move(to: CGPoint(x: center.x - crossLength, y: center.y))
        crossPath.line(to: CGPoint(x: center.x + crossLength, y: center.y))
        crossPath.move(to: CGPoint(x: center.x, y: center.y - crossLength))
        crossPath.line(to: CGPoint(x: center.x, y: center.y + crossLength))
        crossPath.lineWidth = 0.7
        NSColor.black.withAlphaComponent(0.35).setStroke()
        crossPath.stroke()

        let pulseRadius = coreRadius * (0.55 + 0.25 * pulse)
        let pulseRect = NSRect(
            x: center.x - pulseRadius,
            y: center.y - pulseRadius,
            width: pulseRadius * 2,
            height: pulseRadius * 2
        )
        let pulsePath = NSBezierPath(ovalIn: pulseRect)
        pulsePath.lineWidth = 0.9
        NSColor.white.withAlphaComponent(0.4).setStroke()
        pulsePath.stroke()
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
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: 2.5, dy: 2.5)
        let center = CGPoint(x: square.midX, y: square.midY)
        let maxRadius = min(square.width, square.height) / 2

        let outerRadius = maxRadius * 0.86
        let outerPath = NSBezierPath(ovalIn: CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        outerPath.lineWidth = 1
        outerPath.stroke()

        let innerRadius = outerRadius * 0.74
        let innerPath = NSBezierPath(ovalIn: CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
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
        NSColor.labelColor.withAlphaComponent(0.58).setStroke()
        capsulePath.lineWidth = 1
        capsulePath.stroke()

        let stemHeight = capsuleHeight * 0.6
        let stemPath = NSBezierPath()
        stemPath.move(to: CGPoint(x: center.x, y: center.y - stemHeight / 2 - 1))
        stemPath.line(to: CGPoint(x: center.x, y: center.y - stemHeight))
        stemPath.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        stemPath.stroke()

        let baseWidth = capsuleWidth * 0.9
        let basePath = NSBezierPath()
        basePath.move(to: CGPoint(x: center.x - baseWidth / 2, y: center.y - stemHeight - 1.5))
        basePath.line(to: CGPoint(x: center.x + baseWidth / 2, y: center.y - stemHeight - 1.5))
        basePath.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
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
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            arcPath.stroke()
        }

        let highlightRadius = capsuleWidth * 0.3
        let highlightRect = CGRect(
            x: center.x - highlightRadius,
            y: center.y + capsuleHeight * 0.15 - highlightRadius,
            width: highlightRadius * 2,
            height: highlightRadius * 2
        )
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(ovalIn: highlightRect).fill()
    }

    private func drawRecording(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: 2, dy: 2)
        let center = CGPoint(x: square.midX, y: square.midY)
        let maxRadius = min(square.width, square.height) / 2
        let intensity = max(0.05, recordingLevel)
        let swell = 0.5 + 0.5 * sin(animationPhase * 1.5)

        let baseStrokeColor = NSColor.systemRed.withAlphaComponent(0.9)
        let softFillColor = NSColor.systemRed.withAlphaComponent(0.2 + 0.4 * intensity)

        // Outer breathing ring keeps everything centered and small.
        let outerRadius = min(maxRadius - 1, maxRadius * (0.78 + 0.18 * swell + 0.18 * intensity))
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
        let coreRadius = outerRadius * (0.5 + 0.3 * intensity)
        let coreRect = CGRect(
            x: center.x - coreRadius,
            y: center.y - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        )
        softFillColor.setFill()
        NSBezierPath(ovalIn: coreRect).fill()

        // Tall capsule to hint at a mic stem, keeps design symmetric.
        let capsuleHeight = coreRadius * (1.2 + 0.25 * swell)
        let capsuleWidth = coreRadius * 0.58
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
        let openingAngle = 34 + intensity * 48
        let waveLayers = 3
        for layer in 0..<waveLayers {
            let progress = CGFloat(layer) / CGFloat(waveLayers)
            let rawRadius = coreRadius + 4 + progress * (maxRadius * 0.7 - coreRadius)
            let radius = min(rawRadius, maxRadius - 1)
            let alpha = (0.35 - progress * 0.2) * (0.6 + 0.35 * intensity)
            let thickness = 1 + (1 - progress) * 0.5
            let currentOpening = openingAngle + CGFloat(layer) * 7 + intensity * 22
            let start = -currentOpening
            let end = currentOpening
            let phaseShift = animationPhase * (0.8 + CGFloat(layer) * 0.15)

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
        let dotCount = 3
        let spacing: CGFloat = 6
        let radius: CGFloat = 2
        let totalWidth = CGFloat(dotCount - 1) * spacing
        var currentX = rect.midX - totalWidth / 2
        let centerY = rect.midY

        for index in 0..<dotCount {
            let phase = animationPhase + CGFloat(index) * 0.8
            let alpha = 0.25 + 0.65 * (0.5 + 0.5 * sin(phase))
            let dotRect = CGRect(
                x: currentX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            currentX += spacing
        }
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
            self.animationPhase = (self.animationPhase + 0.18).truncatingRemainder(dividingBy: .pi * 2)
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
        case recording(url: URL)
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
    private var preferencesWindowController: PreferencesWindowController?
    private let caretLocator = TextCursorLocator()
    private let cursorOverlay = CursorLevelOverlay()
    private var state: CaptureState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        caretLocator.requestAccessibilityAuthorizationIfNeeded()
        do {
            try configureBridge()
            configureHotkey()
            dictationAdvisor.promptIfNeeded()
            recorder.levelUpdateHandler = { [weak self] level in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let caretPoint = self.caretLocator.currentCaretPoint()
                    self.cursorOverlay.update(level: CGFloat(level), caretPoint: caretPoint)
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

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit FreeWhisperKey", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func configureBridge() throws {
        let bundle = try WhisperBundleResolver.resolve()
        whisperBundle = bundle
        if settings.selectedModelFilename == nil && settings.customModelPath == nil {
            settings.selectedModelFilename = bundle.defaultModel.lastPathComponent
        }
        whisperBridge = try buildBridge(using: bundle)
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

        let modelURL: URL
        if let customPath = settings.customModelPath {
            let customURL = URL(fileURLWithPath: customPath)
            guard FileManager.default.fileExists(atPath: customURL.path) else {
                throw TranscriptionError.bundleMissing("Custom model not found at \(customURL.path).")
            }
            modelURL = customURL
        } else if let fileName = settings.selectedModelFilename {
            let candidate = bundle.modelsDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw TranscriptionError.bundleMissing("Model not found at \(candidate.path).")
            }
            modelURL = candidate
        } else {
            modelURL = bundle.defaultModel
        }

        return WhisperBridge(executableURL: bundle.binary, modelURL: modelURL)
    }

    private func reloadBridge() {
        do {
            whisperBridge = try buildBridge()
        } catch {
            presentAlert(message: "Model Error", informativeText: error.localizedDescription)
            settings.customModelPath = nil
            if let defaultName = whisperBundle?.defaultModel.lastPathComponent {
                settings.selectedModelFilename = defaultName
            }
            whisperBridge = try? buildBridge()
        }
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
                bundle: bundle
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
            presentAlert(message: "Bundle not configured.", informativeText: "Ensure dist/whisper-bundle exists next to the app binary.")
            return
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-\(UUID().uuidString).wav")
        do {
            try recorder.beginRecording(into: audioURL)
            state = .recording(url: audioURL)
            statusIconView.state = .recording
            cursorOverlay.primeAnchor(with: caretLocator.currentCaretPoint())
            cursorOverlay.show()
        } catch {
            state = .idle
            statusIconView.state = .idle
            cursorOverlay.hide()
            presentAlert(message: "Recording Error", informativeText: error.localizedDescription)
        }
    }

    private func finishPressToTalk() {
        guard case .recording(let url) = state else { return }
        cursorOverlay.hide()
        recorder.stopRecording()
        state = .processing
        statusIconView.state = .processing
        transcribeFile(at: url)
    }

    private func transcribeFile(at url: URL) {
        guard let bridge = whisperBridge else {
            presentAlert(message: "Bundle missing", informativeText: "Rebuild whisper bundle.")
            resetState()
            return
        }

        workQueue.async {
            do {
                let text = try bridge.transcribe(audioURL: url)
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
        if settings.autoPasteEnabled {
            do {
                try pasteController.paste(text: text)
            } catch {
                presentAlert(message: "Paste Error", informativeText: error.localizedDescription)
            }
        } else {
            copyToClipboard(text)
            presentAlert(message: "Transcription Complete", informativeText: "Transcript copied to clipboard:\n\n\(text)")
        }
    }

    private func presentProcessingError(_ error: Error) {
        resetState()
        presentAlert(message: "Error", informativeText: error.localizedDescription)
    }

    private func resetState() {
        state = .idle
        statusIconView.state = .idle
        cursorOverlay.hide()
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
}

@main
struct TranscribeMenuAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
