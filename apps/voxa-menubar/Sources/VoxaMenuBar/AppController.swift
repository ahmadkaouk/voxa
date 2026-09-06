import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

final class AppController: ObservableObject {
    private let daemonLabel = "com.voxa.daemon"
    @Published private(set) var connectionStatus: ConnectionStatus = .connecting
    @Published private(set) var runtimeState: RuntimeStateKind = .idle
    @Published private(set) var lastEventName: String = "none"
    @Published private(set) var lastErrorCode: String?
    @Published private(set) var statusMessage: String = "Starting daemon connection..."
    @Published private(set) var isBusy = false
    @Published private(set) var eventSequence: UInt64 = 0
    @Published private(set) var socketPath: String
    @Published private(set) var recordingLevel: Double = 0
    @Published private(set) var recordingOrigin: RecordingOrigin?

    @Published private(set) var configRevision: UInt64 = 0
    @Published private(set) var toggleHotkey: HotkeyOption = .defaultToggle
    @Published private(set) var holdHotkey: HotkeyOption = .defaultHold
    @Published private(set) var model: ModelOption = .gptTranscribe
    @Published private(set) var outputMode: OutputModeOption = .clipboardAutopaste
    @Published private(set) var maxRecordingSeconds: UInt64 = 300
    @Published private(set) var apiKeySource: String = "keychain"
    @Published private(set) var isAPIKeySet = false
    @Published private(set) var apiKeyHint: String?
    @Published private(set) var apiKeySaveCount: UInt64 = 0
    @Published private(set) var apiKeyError: String?
    @Published private(set) var hasAccessibilityPermission = true
    @Published private(set) var lastTranscript: String?
    @Published var apiKeyInput = ""

    private let transport: IPCTransport
    private let hotkeyBridge = GlobalHotkeyBridge()
    private let activityOverlay = ActivityOverlayController()
    private let soundCues = DictationSoundController()
    private let clipboardAutopaster = ClipboardAutopaster()
    private let eventQueue = DispatchQueue(label: "voxa.menubar.events", qos: .userInitiated)
    private let requestQueue = DispatchQueue(label: "voxa.menubar.requests", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "voxa.menubar.output", qos: .userInitiated)
    private let reconnectSignal = DispatchSemaphore(value: 0)

    private let lifecycleLock = NSLock()
    private var shouldStop = false
    private var lastSeenSeq: UInt64 = 0
    private var eventConnection: IPCConnection?
    private var terminationObserver: NSObjectProtocol?
    private var becameActiveObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shutdownHandled = false
    private var overlayDismissedForCurrentRecording = false
    private var hasObservedRuntimeState = false
    private var activityOverlayPhaseOverride: ActivityOverlayPhase?
    private var activityOverlayPhaseResetWorkItem: DispatchWorkItem?
    private var hasPromptedForInputPermissions = false

    init() {
        let path: String
        do {
            path = try IPCTransport.defaultSocketPath()
        } catch {
            path = "/tmp/voxa-daemon.sock"
        }

        socketPath = path
        transport = IPCTransport(socketPath: path)
        hotkeyBridge.onToggleActivated = { [weak self] in
            self?.handleToggleHotkeyActivated()
        }
        hotkeyBridge.onHoldActivated = { [weak self] in
            self?.handleHoldHotkeyActivated()
        }
        hotkeyBridge.onHoldDeactivated = { [weak self] in
            self?.handleHoldHotkeyDeactivated()
        }
        hotkeyBridge.updateBindings(toggle: toggleHotkey, hold: holdHotkey)
        hotkeyBridge.start()
        refreshAccessibilityPermission(prompt: false)
        if !hasAccessibilityPermission {
            _ = refreshAccessibilityPermission(prompt: true)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleAppTermination()
        }
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recoverHotkeyBridgeAfterSystemResume()
        }
        registerWorkspaceObservers()
        startEventLoop()
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        handleAppTermination()
    }

    var menuBarSymbol: String {
        switch connectionStatus {
        case .connected:
            return runtimeState.menuBarSymbol
        case .connecting:
            return "bolt.horizontal.circle"
        case .disconnected:
            return "wifi.exclamationmark"
        }
    }

    private func handleAppTermination() {
        lifecycleLock.lock()
        if shutdownHandled {
            lifecycleLock.unlock()
            return
        }
        shutdownHandled = true
        lifecycleLock.unlock()

        hotkeyBridge.stop()
        stopEventLoop()
        activityOverlay.hide()
        _ = stopLaunchAgentIfNeeded()
    }

    private func registerWorkspaceObservers() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        let activeNotifications: [Notification.Name] = [
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        let inactiveNotifications: [Notification.Name] = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]

        workspaceObservers.append(
            contentsOf: activeNotifications.map { name in
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.recoverHotkeyBridgeAfterSystemResume()
                }
            }
        )

        workspaceObservers.append(
            contentsOf: inactiveNotifications.map { name in
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.hotkeyBridge.resetForSystemInterruption()
                }
            }
        )
    }

    private func recoverHotkeyBridgeAfterSystemResume() {
        _ = refreshAccessibilityPermission(prompt: false)
        hotkeyBridge.restart()
    }

    func startRecording() {
        guard !isBusy, runtimeState == .idle || runtimeState == .error else { return }
        clearActivityOverlayPhaseOverride()
        sendCommand(
            method: "start_recording",
            params: ["origin": "manual"],
            pendingMessage: "Requesting recording start...",
            successMessage: "Recording request accepted",
            refreshStateAfterSuccess: false
        )
    }

    func stopRecording() {
        if runtimeState == .recording {
            transitionOverlayToProcessing()
        }
        sendCommand(
            method: "stop_recording",
            params: ["reason": "manual"],
            pendingMessage: "Requesting recording stop...",
            successMessage: "Recording stop request accepted",
            refreshStateAfterSuccess: false
        )
    }

    func cancelRecordingFromOverlay() {
        guard runtimeState == .recording, !isBusy else { return }
        isBusy = true
        statusMessage = "Cancelling recording..."
        requestQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.transport.request(method: "cancel_recording", params: [:])
                let cancelled = result["cancelled"] as? Bool == true
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.statusMessage = cancelled ? "Recording cancelled" : "Recording has already ended"
                }
                if let state = try? self.transport.getState() {
                    self.publishState(state)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                }
                self.refreshOverlayStateAfterHotkeyError()
            }
        }
    }

    func stopRecordingFromOverlay() {
        overlayDismissedForCurrentRecording = false
        stopRecording()
    }

    func requestInputPermissions() {
        _ = refreshAccessibilityPermission(prompt: true)
        openInputMonitoringSettings()
    }

    func refreshState() {
        sendCommand(
            method: "get_state",
            params: [:],
            pendingMessage: "Refreshing daemon state...",
            successMessage: "State refreshed",
            refreshStateAfterSuccess: true
        )
    }

    func refreshConfig() {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = "Refreshing daemon config..."
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                let config = try self.transport.getConfig()
                let apiKeyStatus = try self.transport.getAPIKeyStatus()
                DispatchQueue.main.async {
                    self.publishConfig(config)
                    self.publishAPIKeyStatus(apiKeyStatus)
                    self.statusMessage = "Config refreshed"
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func setToggleHotkey(_ value: HotkeyOption) {
        if value == toggleHotkey {
            return
        }

        updateConfig(
            params: ["toggle_hotkey": value.persistedValue],
            pendingMessage: "Updating toggle hotkey...",
            successMessage: "Toggle hotkey updated"
        ) { controller in
            controller.toggleHotkey = value
            controller.hotkeyBridge.updateBindings(
                toggle: value,
                hold: controller.holdHotkey
            )
        }
    }

    func setHoldHotkey(_ value: HotkeyOption) {
        if value == holdHotkey {
            return
        }

        updateConfig(
            params: ["hold_hotkey": value.persistedValue],
            pendingMessage: "Updating hold hotkey...",
            successMessage: "Hold hotkey updated"
        ) { controller in
            controller.holdHotkey = value
            controller.hotkeyBridge.updateBindings(
                toggle: controller.toggleHotkey,
                hold: value
            )
        }
    }

    func setHotkeyCaptureEnabled(_ enabled: Bool) {
        hotkeyBridge.setEnabled(!enabled)
    }

    func setModel(_ value: ModelOption) {
        if value == model {
            return
        }

        updateConfig(
            params: ["model": value.rawValue],
            pendingMessage: "Updating model...",
            successMessage: "Model updated"
        ) { controller in
            controller.model = value
        }
    }

    func setOutputMode(_ value: OutputModeOption) {
        if value == outputMode {
            return
        }

        updateConfig(
            params: ["output_mode": value.rawValue],
            pendingMessage: "Updating output mode...",
            successMessage: "Output mode updated"
        ) { controller in
            controller.outputMode = value
        }
    }

    func setMaxRecordingSeconds(_ value: UInt64) {
        let clamped = max(1, min(value, 3600))
        if clamped == maxRecordingSeconds {
            return
        }

        updateConfig(
            params: ["max_recording_seconds": clamped],
            pendingMessage: "Updating max recording duration...",
            successMessage: "Max recording duration updated"
        ) { controller in
            controller.maxRecordingSeconds = clamped
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apiKeyError = "API key cannot be empty"
            statusMessage = "API key cannot be empty"
            return
        }

        DispatchQueue.main.async {
            self.apiKeyError = nil
            self.isBusy = true
            self.statusMessage = "Saving API key..."
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                let result = try self.transport.setAPIKey(trimmed)
                let source = result["source"] as? String
                let hint = String(trimmed.prefix(10)) + "..."
                DispatchQueue.main.async {
                    self.isAPIKeySet = true
                    self.apiKeyHint = hint
                    if let source {
                        self.apiKeySource = source
                    }
                    self.apiKeyError = nil
                    self.statusMessage = "API key saved"
                    self.apiKeySaveCount += 1
                    self.apiKeyInput = ""
                    self.isBusy = false
                    self.syncActivityOverlay()
                }
            } catch {
                DispatchQueue.main.async {
                    self.apiKeyError = error.localizedDescription
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func reconnectNow() {
        lifecycleLock.lock()
        eventConnection?.close()
        eventConnection = nil
        lifecycleLock.unlock()
        reconnectSignal.signal()
    }

    func startDaemon() {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = "Starting daemon..."
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.ensureDaemonRunning()
                DispatchQueue.main.async {
                    self.statusMessage = "Daemon ready"
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    func stopDaemon() {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = "Stopping daemon..."
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            let stopped = self.stopLaunchAgentIfNeeded()

            DispatchQueue.main.async {
                self.statusMessage = stopped
                    ? "Daemon stop requested"
                    : "LaunchAgent service not loaded"
                self.isBusy = false
            }
        }
    }

    func quit() {
        handleAppTermination()
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    private func startEventLoop() {
        eventQueue.async { [weak self] in
            self?.runEventLoop()
        }
    }

    private func stopEventLoop() {
        lifecycleLock.lock()
        shouldStop = true
        eventConnection?.close()
        eventConnection = nil
        lifecycleLock.unlock()
        reconnectSignal.signal()
    }

    private func runEventLoop() {
        let backoffSchedule: [TimeInterval] = [0.2, 0.5, 1.0, 2.0, 5.0]
        var backoffIndex = 0

        while true {
            if isStopping() {
                return
            }

            publishConnectionStatus(.connecting, message: "Starting daemon...")

            do {
                try ensureDaemonRunning()
                publishConnectionStatus(.connecting, message: "Connecting to daemon...")
                // Subscribe before reading snapshots so events emitted during
                // startup/reconnect cannot fall into a snapshot-subscribe gap.
                let subscribeFrom = currentLastSeenSeq()
                let subscription = try transport.subscribe(
                    fromSeq: subscribeFrom == 0 ? nil : subscribeFrom
                )
                let connection = subscription.connection
                reconcileSubscriptionCursor(
                    currentSeq: subscription.currentSeq,
                    previousCursor: subscribeFrom
                )

                lifecycleLock.lock()
                eventConnection = connection
                lifecycleLock.unlock()

                let state = try transport.getState()
                let config = try transport.getConfig()
                let apiKeyStatus = try transport.getAPIKeyStatus()
                publishState(state)
                publishConfig(config)
                publishAPIKeyStatus(apiKeyStatus)

                publishConnectionStatus(.connected, message: "Connected")
                backoffIndex = 0

                while true {
                    if isStopping() {
                        connection.close()
                        return
                    }

                    let envelope = try connection.readEnvelope()
                    switch envelope {
                    case let .event(event):
                        handleEvent(event)
                    default:
                        continue
                    }
                }
            } catch {
                lifecycleLock.lock()
                eventConnection?.close()
                eventConnection = nil
                lifecycleLock.unlock()

                if isStopping() {
                    return
                }

                publishConnectionStatus(
                    .disconnected(message: error.localizedDescription),
                    message: "Disconnected: \(error.localizedDescription). Reconnecting..."
                )

                let sleepDuration = backoffSchedule[min(backoffIndex, backoffSchedule.count - 1)]
                _ = reconnectSignal.wait(timeout: .now() + sleepDuration)
                backoffIndex += 1
            }
        }
    }

    private func handleEvent(_ event: DaemonEventSnapshot) {
        updateLastSeenSeq(event.seq)

        DispatchQueue.main.async {
            self.lastEventName = event.name
            self.eventSequence = event.seq

            if event.name == "state_changed",
               let stateRaw = event.data["state"] as? String,
               let state = RuntimeStateKind(rawValue: stateRaw)
            {
                self.applyRuntimeState(state)
                self.recordingOrigin = state == .recording
                    ? (RecordingOrigin.fromRaw(event.data["recording_origin"] as? String)
                        ?? self.recordingOrigin
                        ?? .manual)
                    : nil
                self.lastErrorCode = event.data["last_error"] as? String
                if state != .recording {
                    self.recordingLevel = 0
                }
                if state == .idle {
                    self.overlayDismissedForCurrentRecording = false
                    if self.activityOverlayPhaseOverride != .outputting {
                        self.clearActivityOverlayPhaseOverride()
                    }
                } else if state == .error {
                    self.clearActivityOverlayPhaseOverride()
                }
                self.syncActivityOverlay()
            } else if event.name == "audio_level",
                      let level = event.data["level"] as? NSNumber
            {
                self.recordingLevel = max(0, min(level.doubleValue, 1))
                self.syncActivityOverlay()
            } else if event.name == "transcription_ready",
                      let text = event.data["text"] as? String
            {
                self.handleTranscriptionReady(text)
            }
        }
    }

    private func sendCommand(
        method: String,
        params: [String: Any],
        pendingMessage: String,
        successMessage: String,
        refreshStateAfterSuccess: Bool
    ) {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = pendingMessage
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                _ = try self.transport.request(method: method, params: params)
                DispatchQueue.main.async {
                    self.statusMessage = successMessage
                    self.isBusy = false
                }

                if refreshStateAfterSuccess, let state = try? self.transport.getState() {
                    self.publishState(state)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
                if method == "stop_recording" {
                    self.refreshOverlayStateAfterHotkeyError()
                }
            }
        }
    }

    private func updateConfig(
        params: [String: Any],
        pendingMessage: String,
        successMessage: String,
        applyAccepted: @escaping (AppController) -> Void
    ) {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = pendingMessage
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                let result = try self.transport.request(method: "set_config", params: params)
                let revision = (result["revision"] as? NSNumber)?.uint64Value

                DispatchQueue.main.async {
                    applyAccepted(self)
                    self.syncActivityOverlay()
                    if let revision {
                        self.configRevision = revision
                    }
                    self.statusMessage = successMessage
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    private func handleToggleHotkeyActivated() {
        DispatchQueue.main.async {
            if self.runtimeState == .recording {
                self.overlayDismissedForCurrentRecording = false
                self.transitionOverlayToProcessing()
            } else {
                self.recordingOrigin = .hotkeyToggle
                self.overlayDismissedForCurrentRecording = false
                self.clearActivityOverlayPhaseOverride()
                self.syncActivityOverlay()
            }
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                let state = try self.transport.getState()
                if state.state == .recording {
                    _ = try self.transport.request(
                        method: "stop_recording",
                        params: ["reason": "hotkey_toggle"]
                    )
                } else {
                    _ = try self.transport.request(
                        method: "start_recording",
                        params: ["origin": "hotkey_toggle"]
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                }
                self.refreshOverlayStateAfterHotkeyError()
            }
        }
    }

    private func handleHoldHotkeyActivated() {
        DispatchQueue.main.async {
            self.recordingOrigin = .hotkeyHold
            self.overlayDismissedForCurrentRecording = false
            self.clearActivityOverlayPhaseOverride()
            self.syncActivityOverlay()
        }

        sendHotkeyCommand(
            method: "start_recording",
            params: ["origin": "hotkey_hold"]
        )
    }

    private func handleHoldHotkeyDeactivated() {
        DispatchQueue.main.async {
            self.overlayDismissedForCurrentRecording = false
            // Cancel may already have returned to idle while the key is still held.
            if self.runtimeState == .recording {
                self.transitionOverlayToProcessing()
            }
        }

        sendHotkeyCommand(
            method: "stop_recording",
            params: ["reason": "hotkey_hold_release"]
        )
    }

    private func sendHotkeyCommand(method: String, params: [String: Any]) {
        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                _ = try self.transport.request(method: method, params: params)
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                }
                self.refreshOverlayStateAfterHotkeyError()
            }
        }
    }

    private func handleTranscriptionReady(_ text: String) {
        setActivityOverlayPhaseOverride(.outputting, autoClearAfter: 0.45)
        syncActivityOverlay()

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Transcript ready (empty)"
            return
        }
        lastTranscript = text
        let mode = outputMode
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let canPaste = mode == .clipboardAutopaste
            && refreshAccessibilityPermission(prompt: false)
            && targetPID != nil && targetPID != getpid()

        statusMessage = "Sending transcript…"
        outputQueue.async { [weak self] in
            guard let self else { return }
            let message = processTranscriptOutput(
                text: text,
                mode: mode,
                copyToClipboard: self.writeTextToClipboard,
                autopaste: { value in
                    self.clipboardAutopaster.paste(value) { ownedCount in
                        guard canPaste, let targetPID else { return false }
                        return sendPasteShortcut(to: targetPID, clipboardChangeCount: ownedCount)
                    }.message
                }
            )
            DispatchQueue.main.async {
                self.statusMessage = message
            }
        }
    }

    func copyLastTranscript() {
        guard let text = lastTranscript else { return }
        // Serialize explicit copies with paste/restore, so an earlier paste can
        // never restore its saved clipboard over a requested transcript copy.
        outputQueue.async { [weak self] in
            guard let self else { return }
            let copied = self.writeTextToClipboard(text)
            DispatchQueue.main.async {
                self.statusMessage = copied
                    ? "Last transcript copied to clipboard"
                    : "Could not copy last transcript"
            }
        }
    }

    private func writeTextToClipboard(_ text: String) -> Bool {
        onPasteboardThread {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }

    @discardableResult
    private func refreshAccessibilityPermission(prompt: Bool) -> Bool {
        let shouldPrompt = prompt && !hasPromptedForInputPermissions
        if shouldPrompt {
            hasPromptedForInputPermissions = true
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt]
            as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
        if !trusted {
            statusMessage = "Grant Accessibility/Input Monitoring for hotkeys and autopaste"
        }
        return trusted
    }

    private func openInputMonitoringSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func publishState(_ snapshot: DaemonStateSnapshot) {
        DispatchQueue.main.async {
            self.applyRuntimeState(snapshot.state)
            self.recordingOrigin = snapshot.state == .recording
                ? (RecordingOrigin.fromRaw(snapshot.recordingOrigin) ?? .manual)
                : nil
            self.lastErrorCode = snapshot.lastError
            self.eventSequence = max(self.eventSequence, snapshot.eventSeq)
            if snapshot.state != .recording {
                self.recordingLevel = 0
            }
            if snapshot.state == .idle {
                self.overlayDismissedForCurrentRecording = false
                if self.activityOverlayPhaseOverride != .outputting {
                    self.clearActivityOverlayPhaseOverride()
                }
            } else if snapshot.state == .error {
                self.clearActivityOverlayPhaseOverride()
            }
            self.syncActivityOverlay()
        }
    }

    private func applyRuntimeState(_ state: RuntimeStateKind) {
        let previousState = runtimeState
        runtimeState = state

        guard hasObservedRuntimeState else {
            hasObservedRuntimeState = true
            return
        }

        guard previousState != state else {
            return
        }

        if state == .recording {
            soundCues.playListeningStarted()
        } else if state == .error {
            soundCues.playError()
        } else if previousState == .recording {
            soundCues.playRecordingEnded()
        }
    }

    private func publishConfig(_ snapshot: DaemonConfigSnapshot) {
        DispatchQueue.main.async {
            self.toggleHotkey = HotkeyOption.fromRawOrDefault(
                snapshot.toggleHotkey,
                fallback: .defaultToggle
            )
            self.holdHotkey = HotkeyOption.fromRawOrDefault(
                snapshot.holdHotkey,
                fallback: .defaultHold
            )
            self.model = ModelOption.fromRawOrDefault(snapshot.model)
            self.outputMode = OutputModeOption.fromRawOrDefault(snapshot.outputMode)
            self.maxRecordingSeconds = snapshot.maxRecordingSeconds
            self.configRevision = snapshot.revision
            self.hotkeyBridge.updateBindings(toggle: self.toggleHotkey, hold: self.holdHotkey)
            self.syncActivityOverlay()
        }
    }

    private func publishAPIKeyStatus(_ snapshot: ApiKeyStatusSnapshot) {
        DispatchQueue.main.async {
            self.apiKeySource = snapshot.source
            self.isAPIKeySet = snapshot.isSet
            self.apiKeyHint = snapshot.hint
            self.syncActivityOverlay()
        }
    }

    private func publishConnectionStatus(_ status: ConnectionStatus, message: String) {
        DispatchQueue.main.async {
            self.connectionStatus = status
            if !status.isConnected {
                self.recordingLevel = 0
                self.recordingOrigin = nil
                self.clearActivityOverlayPhaseOverride()
            }
            self.statusMessage = message
            self.syncActivityOverlay()
        }
    }

    private func syncActivityOverlay() {
        switch connectionStatus {
        case .connected:
            if let phase = currentActivityOverlayPhase(), !overlayDismissedForCurrentRecording {
                showActivityOverlay(phase)
            } else {
                activityOverlay.hide()
            }
        case .connecting, .disconnected:
            self.activityOverlay.hide()
        }
    }

    private func refreshOverlayStateAfterHotkeyError() {
        let state = try? transport.getState()

        DispatchQueue.main.async {
            if self.activityOverlayPhaseOverride == .transcribing {
                self.clearActivityOverlayPhaseOverride()
            }
            if let state {
                self.publishState(state)
            } else {
                self.recordingOrigin = nil
                self.clearActivityOverlayPhaseOverride()
                self.activityOverlay.hide()
            }
        }
    }

    private func transitionOverlayToProcessing() {
        setActivityOverlayPhaseOverride(.transcribing)
        syncActivityOverlay()
    }

    private func showActivityOverlay(_ phase: ActivityOverlayPhase) {
        activityOverlay.show(
            phase,
            content: currentActivityOverlayContent(for: phase),
            level: recordingLevel,
            onStart: { [weak self] in
                self?.startRecording()
            },
            onCancel: { [weak self] in
                self?.cancelRecordingFromOverlay()
            },
            onStop: { [weak self] in
                self?.stopRecordingFromOverlay()
            }
        )
    }

    private func currentActivityOverlayPhase() -> ActivityOverlayPhase? {
        if let activityOverlayPhaseOverride {
            return activityOverlayPhaseOverride
        }

        switch runtimeState {
        case .recording:
            return .listening
        case .transcribing:
            return .transcribing
        case .outputting:
            return .outputting
        case .idle:
            return isAPIKeySet ? .idle : nil
        case .error:
            return nil
        }
    }

    private func currentActivityOverlayContent(for phase: ActivityOverlayPhase) -> ActivityOverlayContent {
        switch phase {
        case .idle:
            return ActivityOverlayContent(title: "Start dictation", subtitle: toggleHotkey.label)
        case .listening:
            return ActivityOverlayContent(title: "Listening", subtitle: nil)
        case .transcribing:
            return ActivityOverlayContent(title: "Transcribing", subtitle: nil)
        case .outputting:
            let title: String
            switch outputMode {
            case .clipboardAutopaste:
                title = "Sending Text"
            case .clipboardOnly:
                title = "Copying Text"
            case .none:
                title = "Transcript Ready"
            }
            return ActivityOverlayContent(title: title, subtitle: nil)
        }
    }

    private func setActivityOverlayPhaseOverride(
        _ phase: ActivityOverlayPhase?,
        autoClearAfter delay: TimeInterval? = nil
    ) {
        activityOverlayPhaseResetWorkItem?.cancel()
        activityOverlayPhaseResetWorkItem = nil
        activityOverlayPhaseOverride = phase

        guard let delay, phase != nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activityOverlayPhaseOverride = nil
            self.syncActivityOverlay()
        }
        activityOverlayPhaseResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearActivityOverlayPhaseOverride() {
        setActivityOverlayPhaseOverride(nil)
    }

    private func isStopping() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return shouldStop
    }

    private func currentLastSeenSeq() -> UInt64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return lastSeenSeq
    }

    private func updateLastSeenSeq(_ value: UInt64) {
        lifecycleLock.lock()
        if value < lastSeenSeq {
            // A lower live/replayed event sequence starts a fresh daemon epoch.
            lastSeenSeq = value
        } else if value > lastSeenSeq {
            lastSeenSeq = value
        }
        lifecycleLock.unlock()
    }

    private func reconcileSubscriptionCursor(currentSeq: UInt64, previousCursor: UInt64) {
        lifecycleLock.lock()
        if previousCursor == 0 {
            // Establish the initial subscription cutoff. For a lower sequence
            // after restart, retain the old cursor until the first replayed
            // event arrives so an interrupted replay can be requested again.
            lastSeenSeq = currentSeq
        }
        lifecycleLock.unlock()
    }

    private var launchDomain: String {
        "gui/\(getuid())"
    }

    private var launchTarget: String {
        "\(launchDomain)/\(daemonLabel)"
    }

    private var launchAgentPlistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(daemonLabel).plist"
    }

    private var daemonLogsDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Logs/voxa"
    }

    private func ensureDaemonRunning() throws {
        if daemonIsReachable() {
            return
        }

        guard let daemonPath = resolveDaemonExecutablePath() else {
            throw NSError(
                domain: "voxa.daemon",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve voxa-daemon executable path for LaunchAgent installation"]
            )
        }

        try ensureLaunchAgentInstalled(daemonPath: daemonPath)
        if waitForDaemonAvailability(timeout: 0.3) {
            return
        }

        launchDaemonWithLaunchctl()
        if waitForDaemonAvailability(timeout: 1.2) {
            return
        }

        throw NSError(
            domain: "voxa.daemon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to start voxa-daemon via launchd"]
        )
    }

    private func daemonIsReachable() -> Bool {
        transport.isReachable()
    }

    private func waitForDaemonAvailability(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if daemonIsReachable() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func launchDaemonWithLaunchctl() {
        _ = try? runProcess(executable: "/bin/launchctl", arguments: ["kickstart", launchTarget])
    }

    private func ensureLaunchAgentInstalled(daemonPath: String) throws {
        let fileManager = FileManager.default
        let launchAgentsDirectory = NSString(string: launchAgentPlistPath).deletingLastPathComponent
        try fileManager.createDirectory(atPath: launchAgentsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: daemonLogsDirectory, withIntermediateDirectories: true)

        let stdoutPath = "\(daemonLogsDirectory)/daemon.out.log"
        let stderrPath = "\(daemonLogsDirectory)/daemon.err.log"
        if !fileManager.fileExists(atPath: stdoutPath) {
            _ = fileManager.createFile(atPath: stdoutPath, contents: nil)
        }
        if !fileManager.fileExists(atPath: stderrPath) {
            _ = fileManager.createFile(atPath: stderrPath, contents: nil)
        }

        let plist = buildLaunchAgentPlist(
            daemonPath: daemonPath,
            stdoutPath: stdoutPath,
            stderrPath: stderrPath
        )
        let currentPlist = try? String(contentsOfFile: launchAgentPlistPath, encoding: .utf8)
        if currentPlist == plist {
            if !isLaunchAgentLoaded() {
                try bootstrapLaunchAgent()
            }
            return
        }

        try plist.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
        _ = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", launchDomain, launchAgentPlistPath]
        )
        try bootstrapLaunchAgent()
    }

    private func isLaunchAgentLoaded() -> Bool {
        (try? runProcess(executable: "/bin/launchctl", arguments: ["print", launchTarget])) != nil
    }

    private func bootstrapLaunchAgent() throws {
        do {
            _ = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootstrap", launchDomain, launchAgentPlistPath]
            )
        } catch {
            if isServiceAlreadyLoadedError(error) {
                return
            }
            throw error
        }
    }

    private func isServiceAlreadyLoadedError(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("already loaded")
    }

    private func buildLaunchAgentPlist(
        daemonPath: String,
        stdoutPath: String,
        stderrPath: String
    ) -> String {
        let escapedLabel = xmlEscape(daemonLabel)
        let escapedDaemonPath = xmlEscape(daemonPath)
        let escapedStdoutPath = xmlEscape(stdoutPath)
        let escapedStderrPath = xmlEscape(stderrPath)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(escapedLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(escapedDaemonPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
          <key>StandardOutPath</key>
          <string>\(escapedStdoutPath)</string>
          <key>StandardErrorPath</key>
          <string>\(escapedStderrPath)</string>
        </dict>
        </plist>
        """
    }

    private func xmlEscape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func stopLaunchAgentIfNeeded() -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: launchAgentPlistPath),
           (try? runProcess(
               executable: "/bin/launchctl",
               arguments: ["bootout", launchDomain, launchAgentPlistPath]
           )) != nil
        {
            return true
        }

        return (try? runProcess(executable: "/bin/launchctl", arguments: ["bootout", launchTarget])) != nil
    }

    private func resolveDaemonExecutablePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let bundledResourceURL = Bundle.main.resourceURL {
            candidates.append(
                bundledResourceURL
                    .appendingPathComponent("bin/voxa-daemon")
                    .standardizedFileURL
                    .path
            )
        }

        if let override = env["VOXA_DAEMON_BIN"], !override.isEmpty {
            candidates.append(override)
        }

        if let pathEnv = env["PATH"] {
            for entry in pathEnv.split(separator: ":") {
                candidates.append("\(entry)/voxa-daemon")
            }
        }

        candidates.append("~/.cargo/bin/voxa-daemon")
        candidates.append("/opt/homebrew/bin/voxa-daemon")
        candidates.append("/usr/local/bin/voxa-daemon")

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(
            cwd
                .appendingPathComponent("../../target/debug/voxa-daemon")
                .standardizedFileURL
                .path
        )
        candidates.append(
            cwd
                .appendingPathComponent("../target/debug/voxa-daemon")
                .standardizedFileURL
                .path
        )

        for candidate in candidates {
            let expanded = NSString(string: candidate).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        return nil
    }
}

private func runProcess(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stderrText = String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let stdoutText = String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    guard process.terminationStatus == 0 else {
        let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = ([executable] + arguments).joined(separator: " ")
        if message.isEmpty {
            throw NSError(
                domain: "voxa.process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Command failed (\(process.terminationStatus)): \(command)"]
            )
        }

        throw NSError(
            domain: "voxa.process",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    return stdoutText
}
