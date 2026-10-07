import AppKit
import Combine
import SwiftUI

/// Application setup, presentation effects, and OS lifecycle wiring. DictationSession owns all
/// recording state.
@MainActor
final class AppController: ObservableObject {
    let session: DictationSession
    let practice: PracticeController
    let feedback = FeedbackController()
    @Published private(set) var preferences = Preferences()
    @Published private(set) var isSettingUp = false
    @Published private(set) var isSavingKey = false
    @Published private(set) var isReady = false
    @Published private(set) var setupError: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var permissions = Permissions.current()
    @Published private(set) var isAPIKeySet = false
    @Published private(set) var apiKeyError: String?
    @Published var apiKeyInput = ""

    private let store: PreferencesStore
    private let keychain: Keychain
    private let hotkeys = GlobalHotkeyBridge()
    private let overlay = ActivityOverlayController()
    private let feedbackPanel = FeedbackPanelController()
    private let practiceWindow = PracticeWindowController()
    private let sounds = DictationSoundController()
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var setupTask: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    private var completionPresentation: Task<Void, Never>?
    private var showingPasteCompletion = false
    private var overlayCancelled = false
    private var closing = false
    private var capturingHotkey = false

    init() {
        let recorder = AudioRecorder()
        session = DictationSession(recorder: recorder,
                                   transcriber: TranscriptionClient(endpoint: TranscriptionClient.configuredEndpoint()),
                                   timingLog: DictationTimingLog.configured())
        practice = PracticeController(recorder: recorder)
        store = PreferencesStore()
        keychain = Keychain()
        practice.prepare = { [weak self] microphone in
            guard let self, !self.closing, self.session.state.context == nil else { throw CancellationError() }
            let key: String
            if microphone { key = try await self.recordingPreparation()() }
            else {
                guard let value = try await self.keychain.value(source: self.preferences.apiKeySource) else {
                    throw TranscriptionError.authentication
                }
                key = value
            }
            return PracticeCredentials(apiKey: key, model: self.model)
        }
        practice.isSavedLesson = { [weak self] id in self?.feedback.saved.contains { $0.id == id } ?? false }
        feedback.onPractice = { [weak self] target in
            guard let self, self.canOpenPractice else { return }
            self.practice.open([target])
        }
        feedback.onLessonsDeleted = { [weak self] ids in self?.practice.lessonsDeleted(ids) }
        practice.$isPresented.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            self.feedback.setPracticeActive(visible)
            if visible {
                self.completionPresentation?.cancel(); self.overlay.hide()
                self.practiceWindow.show(self.practice)
            } else { self.practiceWindow.hide() }
            self.objectWillChange.send()
        }.store(in: &subscriptions)
        practice.$phase.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.present(self.session.state, level: self.session.level)
            }
        }.store(in: &subscriptions)
        practice.history.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        session.onFeedbackTranscript = { [weak self] id, text, key, context in
            self?.feedback.analyze(id: id, transcript: text, apiKey: key, context: context)
        }
        session.onDeliveryFinished = { [weak self] id in self?.feedback.deliveryFinished(id: id) }
        feedback.$panelVisible.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible { self.feedbackPanel.show(self.feedback) }
            else { self.feedbackPanel.hide() }
        }.store(in: &subscriptions)
        feedback.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        hotkeys.onSaveFeedback = { [weak self] in
            guard let self, self.isReady, !self.closing, !self.capturingHotkey else { return false }
            return self.feedback.saveAndClose()
        }
        hotkeys.onDiscardFeedback = { [weak self] in
            guard let self, self.isReady, !self.closing, !self.capturingHotkey else { return false }
            return self.feedback.discardReview()
        }
        hotkeys.onCancelDictation = { [weak self] in
            guard let self, self.isReady, !self.closing, !self.capturingHotkey else { return false }
            // Hide immediately, including while the recorder releases its device.
            let wasCancelled = self.overlayCancelled
            self.overlayCancelled = true
            guard self.session.cancel() else { self.overlayCancelled = wasCancelled; return false }
            self.overlay.hide()
            return true
        }
        hotkeys.onFinishAndSubmit = { [weak self] in
            guard let self, self.canStart,
                  let target = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
            return self.session.stopAndSubmit(to: target)
        }
        hotkeys.onToggleActivated = { [weak self] in
            guard let self, self.canStart else { return }
            self.session.toggle(prepare: self.recordingPreparation())
        }
        session.$state.removeDuplicates().scan((DictationState.idle, DictationState.idle)) { ($0.1, $1) }
            .sink { [weak self] previous, next in
                guard let self else { return }
                if case .starting = next, previous.context?.id != next.context?.id { self.overlayCancelled = false }
                self.feedback.updateDictation(next)
                self.objectWillChange.send() // MenuBarExtra's symbol also observes this controller.
                if case .recording = next { self.sounds.play(.listeningStarted) }
                if case .transcribing = next { self.sounds.play(.recordingEnded) }
                if case .failed = next { self.sounds.play(.error) }
                if case .idle = next, previous.isDiscarding { self.sounds.play(.recordingEnded) }
                self.present(next, level: self.session.level)
            }.store(in: &subscriptions)
        session.$level.removeDuplicates().sink { [weak self] level in
            guard let self, self.isReady, !self.closing,
                  case .recording = self.session.state else { return }
            self.overlay.updateLevel(level)
        }.store(in: &subscriptions)
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshPermissions() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { $0.refreshPermissions() }
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { controller in
                controller.hotkeys.resetForSystemInterruption()
                controller.session.cancel()
                controller.practice.close()
            }
        }
        retrySetup()
    }

    var isBusy: Bool { session.state.isBusy || practice.isBusy || isSettingUp || isSavingKey }
    var canEditDictationSettings: Bool { isReady && !practice.isBusy && !isSettingUp && !isSavingKey && !closing }
    private var canStart: Bool { isReady && !isSettingUp && !isSavingKey && !closing && !capturingHotkey && !practice.isPresented && !practice.isBusy }
    var canOpenPractice: Bool { canStart && session.state.context == nil }
    func showPractice() { if practice.isPresented { practiceWindow.show(practice) } }
    func startShortReview() {
        guard canOpenPractice, practice.history.ready, !practice.history.isSaving, practice.history.error == nil else { return }
        practice.open(practice.history.queue(from: feedback.saved, patterns: feedback.progress.patterns), review: true)
    }
    var toggleHotkey: HotkeyOption { HotkeyOption.fromRawOrDefault(preferences.toggleHotkey) }
    var finishAndSubmitHotkey: HotkeyOption { HotkeyOption.fromRawOrDefault(preferences.finishAndSubmitHotkey, fallback: .defaultFinishAndSubmit) }
    var saveFeedbackHotkey: HotkeyOption { HotkeyOption.fromRawOrDefault(preferences.saveFeedbackHotkey, fallback: .defaultSaveFeedback) }
    var cancelHotkey: HotkeyOption { HotkeyOption.fromRawOrDefault(preferences.cancelHotkey, fallback: .defaultCancel) }
    var model: ModelOption { session.settings.model }
    var outputMode: OutputModeOption { session.settings.outputMode }
    var maxRecordingSeconds: UInt64 { preferences.maxRecordingSeconds }
    var apiKeySource: String { preferences.apiKeySource }
    var errorMessage: String? {
        if case .failed(_, let message) = session.state { return message }
        return setupError ?? settingsError
    }
    var menuBarSymbol: String {
        if setupError != nil { return "exclamationmark.triangle" }
        switch session.state {
        case .idle, .starting, .recording, .restoringClipboard: return "waveform"
        case .finishing, .transcribing: return "waveform.and.mic"
        case .delivering: return "square.and.arrow.up"
        case .failed: return "exclamationmark.triangle"
        }
    }

    func retrySetup() {
        guard !isBusy, !closing else { return }
        isSettingUp = true; isReady = false; setupError = nil; settingsError = nil
        hotkeys.stop()
        setupTask = Task {
            defer { isSettingUp = false }
            do {
                let loaded = try store.load()
                preferences = loaded
                feedback.setEnabled(loaded.englishFeedbackEnabled)
                _ = session.updateSettings(loaded.dictation)
                try CaptureGuard.check()
                let key = try await keychain.value(source: loaded.apiKeySource)
                try Task.checkCancellation()
                guard !closing else { return }
                isAPIKeySet = key != nil
                isReady = true
                updateHotkeyBindings()
                refreshPermissions()
                present(session.state, level: session.level)
            } catch {
                guard !closing else { return }
                setupError = error.localizedDescription
                overlay.hide()
            }
        }
    }

    private func recordingPreparation() -> @MainActor () async throws -> String {
        let source = preferences.apiKeySource
        return { [weak self] in
            guard let self, !self.closing else { throw CancellationError() }
            try CaptureGuard.check()
            defer { self.permissions = Permissions.current() }
            try await Permissions.requestMicrophone()
            try Task.checkCancellation()
            guard let key = try await self.keychain.value(source: source) else {
                self.isAPIKeySet = false
                throw TranscriptionError.authentication
            }
            try Task.checkCancellation()
            try CaptureGuard.check() // Another copy may have launched during a prompt.
            return key
        }
    }

    func startRecording() {
        guard canStart else { return }
        session.start(prepare: recordingPreparation())
    }
    func setHotkeyCaptureEnabled(_ enabled: Bool) {
        capturingHotkey = enabled
        hotkeys.setEnabled(!enabled)
    }

    private func update(duringDictation: Bool = false, _ change: (inout Preferences) -> Void) {
        guard canEditDictationSettings, duringDictation || !session.state.isBusy else { return }
        var next = preferences
        change(&next)
        do {
            try store.save(next)
            _ = session.updateSettings(next.dictation)
            let hotkeysChanged = next.toggleHotkey != preferences.toggleHotkey || next.finishAndSubmitHotkey != preferences.finishAndSubmitHotkey
                || next.saveFeedbackHotkey != preferences.saveFeedbackHotkey || next.cancelHotkey != preferences.cancelHotkey
            if !next.automaticContextEnabled || next.contextExcludedApps != preferences.contextExcludedApps {
                feedback.contextPreferencesChanged()
            }
            preferences = next
            feedback.setEnabled(next.englishFeedbackEnabled)
            settingsError = nil
            // Non-shortcut edits leave physical key tracking alone.
            if hotkeysChanged {
                updateHotkeyBindings()
                present(session.state, level: session.level)
            }
        } catch { settingsError = error.localizedDescription }
    }
    private func updateHotkeyBindings() {
        hotkeys.updateBindings(toggle: toggleHotkey, finishAndSubmit: finishAndSubmitHotkey,
                               saveFeedback: saveFeedbackHotkey, cancel: cancelHotkey)
        feedback.updateShortcuts(save: saveFeedbackHotkey, cancel: cancelHotkey)
    }

    private func acceptsShortcut(_ value: HotkeyOption, replacing title: String) -> Bool {
        let bindings = [("Start / Stop", toggleHotkey), ("Finish & Send", finishAndSubmitHotkey),
                        ("Save feedback", saveFeedbackHotkey), ("Cancel / Close", cancelHotkey)]
        if let conflict = bindings.first(where: { $0.0 != title && value.overlaps($0.1) }) {
            settingsError = "Choose a shortcut that doesn’t overlap \(conflict.0)."; return false
        }
        return true
    }

    func setToggleHotkey(_ value: HotkeyOption) {
        guard acceptsShortcut(value, replacing: "Start / Stop") else { return }
        update { $0.toggleHotkey = value.persistedValue }
    }
    func setFinishAndSubmitHotkey(_ value: HotkeyOption) {
        guard value.isValidForSubmit else {
            settingsError = "Finish & Send needs one key plus a modifier, such as Option + G."; return
        }
        guard acceptsShortcut(value, replacing: "Finish & Send") else { return }
        update { $0.finishAndSubmitHotkey = value.persistedValue }
    }
    func setSaveFeedbackHotkey(_ value: HotkeyOption) {
        guard value.isValidForSubmit else {
            settingsError = "Save feedback needs one key plus a modifier, such as Command + S."; return
        }
        guard acceptsShortcut(value, replacing: "Save feedback") else { return }
        update { $0.saveFeedbackHotkey = value.persistedValue }
    }
    func setCancelHotkey(_ value: HotkeyOption) {
        guard value.isValidForCancel else {
            settingsError = "Cancel / Close needs Escape or one key plus a modifier."; return
        }
        guard acceptsShortcut(value, replacing: "Cancel / Close") else { return }
        update { $0.cancelHotkey = value.persistedValue }
    }
    func setModel(_ value: ModelOption) { update(duringDictation: true) { $0.model = value.rawValue } }
    func setOutputMode(_ value: OutputModeOption) { update(duringDictation: true) { $0.outputMode = value.rawValue } }
    func setMaxRecordingSeconds(_ value: UInt64) { update(duringDictation: true) { $0.maxRecordingSeconds = value } }
    func setEnglishFeedbackEnabled(_ value: Bool) { update(duringDictation: true) { $0.englishFeedbackEnabled = value } }
    func setAutomaticContextEnabled(_ value: Bool) { update(duringDictation: true) { $0.automaticContextEnabled = value } }
    func excludeContextApp(_ app: ContextExcludedApp) {
        update(duringDictation: true) {
            if !$0.contextExcludedApps.contains(where: { $0.bundleID == app.bundleID }) { $0.contextExcludedApps.append(app) }
        }
    }
    func allowContextApp(_ bundleID: String) {
        update(duringDictation: true) { $0.contextExcludedApps.removeAll { $0.bundleID == bundleID } }
    }

    func saveAPIKey() {
        guard !isBusy, !closing else { return }
        let key = apiKeyInput
        let source = preferences.apiKeySource
        isSavingKey = true; apiKeyError = nil
        keyTask = Task {
            do {
                try await keychain.save(key, source: source)
                guard !closing else { return }
                apiKeyInput = ""; isAPIKeySet = true
            } catch { if !closing { apiKeyError = error.localizedDescription } }
            isSavingKey = false
            if !closing, apiKeyError == nil { retrySetup() }
        }
    }

    func copyLastTranscript() {
        Task { _ = await session.copyLastTranscript() }
    }

    func refreshPermissions() {
        guard !closing else { return }
        permissions = Permissions.current()
        if isReady {
            hotkeys.restart()
            hotkeys.setEnabled(!capturingHotkey)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (AppController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, !self.closing { action(self) } }
        }
        observers.append((center, token))
    }

    private func show(_ phase: ActivityOverlayPhase, title: String, level: Double = 0) {
        guard !closing, isReady else { return }
        overlay.show(phase, content: ActivityOverlayContent(title: title, subtitle: phase == .idle ? toggleHotkey.label : nil,
                     cancelShortcut: cancelHotkey.symbolLabel),
                     level: level, onStart: { [weak self] in self?.startRecording() },
                     onCancel: { [weak self] in self?.session.cancel() },
                     onStop: { [weak self] in self?.session.stop() })
    }

    private func present(_ state: DictationState, level: Double) {
        guard isReady, !closing, !practice.isPresented, !practice.isBusy else { overlay.hide(); return }
        guard !overlayCancelled, !state.isDiscarding else { overlay.hide(); return }
        // A paste read already started the checkmark. Finishing clipboard cleanup
        // must neither delay it nor restart its display timer.
        if showingPasteCompletion {
            if case .restoringClipboard = state { return }
            if case .idle = state, session.lastOutcome?.showsSuccess == true { return }
        }
        completionPresentation?.cancel()
        showingPasteCompletion = false
        switch state {
        case .starting(_, let requested):
            if requested == nil { show(.listening, title: "Preparing microphone…") }
            else { show(.transcribing, title: "Finishing recording…") }
        case .recording: show(.listening, title: "Listening", level: level)
        case .finishing: show(.transcribing, title: "Finishing recording…")
        case .transcribing: show(.transcribing, title: "Transcribing")
        case .delivering: show(.transcribing, title: "Delivering transcript…")
        case .restoringClipboard:
            showingPasteCompletion = true
            showCompletion(title: "Transcript pasted")
        case .failed: overlay.hide()
        case .idle:
            if let outcome = session.lastOutcome, outcome.showsSuccess {
                showCompletion(title: outcome.message)
                return
            }
            overlay.hide()
        }
    }

    private func showCompletion(title: String) {
        showingPasteCompletion = true
        show(.outputting, title: title)
        completionPresentation = Task {
            do { try await Task.sleep(nanoseconds: 900_000_000) } catch { return }
            guard !closing else { return }
            switch session.state {
            case .idle, .restoringClipboard: overlay.hide()
            default: break
            }
        }
    }

    func shutdown() async {
        guard !closing else { return }
        closing = true
        hotkeys.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        completionPresentation?.cancel(); setupTask?.cancel(); keyTask?.cancel()
        overlay.hide()
        feedbackPanel.hide()
        practiceWindow.hide()
        await practice.shutdown()
        await feedback.shutdown()
        await session.shutdown()
        await setupTask?.value
        await keyTask?.value
        apiKeyInput = ""
    }
    func quit() { NSApplication.shared.terminate(nil) }
}

@MainActor
final class VoxaAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let controller = AppController()
    private var terminationRequested = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminationRequested {
            terminationRequested = true
            Task {
                await controller.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
