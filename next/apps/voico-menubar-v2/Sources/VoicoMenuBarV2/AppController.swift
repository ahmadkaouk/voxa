import AppKit
import Foundation

final class AppController: ObservableObject {
    private let daemonLabel = "com.voico.v2.daemon"
    @Published private(set) var connectionStatus: ConnectionStatus = .connecting
    @Published private(set) var runtimeState: RuntimeStateKind = .idle
    @Published private(set) var lastEventName: String = "none"
    @Published private(set) var lastErrorCode: String?
    @Published private(set) var statusMessage: String = "Starting daemon connection..."
    @Published private(set) var isBusy = false
    @Published private(set) var eventSequence: UInt64 = 0
    @Published private(set) var socketPath: String

    @Published private(set) var configRevision: UInt64 = 0
    @Published private(set) var toggleHotkey: HotkeyOption = .rightOption
    @Published private(set) var holdHotkey: HotkeyOption = .functionKey
    @Published private(set) var model: ModelOption = .gpt4oMiniTranscribe
    @Published private(set) var outputMode: OutputModeOption = .clipboardAutopaste
    @Published private(set) var maxRecordingSeconds: UInt64 = 300

    private let transport: IPCTransport
    private let eventQueue = DispatchQueue(label: "voico.v2.menubar.events", qos: .userInitiated)
    private let requestQueue = DispatchQueue(label: "voico.v2.menubar.requests", qos: .userInitiated)

    private let lifecycleLock = NSLock()
    private var shouldStop = false
    private var lastSeenSeq: UInt64 = 0
    private var eventConnection: IPCConnection?

    init() {
        let path: String
        do {
            path = try IPCTransport.defaultSocketPath()
        } catch {
            path = "/tmp/voico-v2-daemon.sock"
        }

        socketPath = path
        transport = IPCTransport(socketPath: path)
        startEventLoop()
    }

    deinit {
        stopEventLoop()
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

    func startRecording() {
        sendCommand(
            method: "start_recording",
            params: ["origin": "manual"],
            pendingMessage: "Requesting recording start...",
            successMessage: "Recording request accepted"
        )
    }

    func stopRecording() {
        sendCommand(
            method: "stop_recording",
            params: ["reason": "manual"],
            pendingMessage: "Requesting recording stop...",
            successMessage: "Recording stop request accepted"
        )
    }

    func refreshState() {
        sendCommand(
            method: "get_state",
            params: [:],
            pendingMessage: "Refreshing daemon state...",
            successMessage: "State refreshed"
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
                DispatchQueue.main.async {
                    self.publishConfig(config)
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
            params: ["toggle_hotkey": value.rawValue],
            pendingMessage: "Updating toggle hotkey...",
            successMessage: "Toggle hotkey updated"
        )
    }

    func setHoldHotkey(_ value: HotkeyOption) {
        if value == holdHotkey {
            return
        }

        updateConfig(
            params: ["hold_hotkey": value.rawValue],
            pendingMessage: "Updating hold hotkey...",
            successMessage: "Hold hotkey updated"
        )
    }

    func setModel(_ value: ModelOption) {
        if value == model {
            return
        }

        updateConfig(
            params: ["model": value.rawValue],
            pendingMessage: "Updating model...",
            successMessage: "Model updated"
        )
    }

    func setOutputMode(_ value: OutputModeOption) {
        if value == outputMode {
            return
        }

        updateConfig(
            params: ["output_mode": value.rawValue],
            pendingMessage: "Updating output mode...",
            successMessage: "Output mode updated"
        )
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
        )
    }

    func reconnectNow() {
        lifecycleLock.lock()
        eventConnection?.close()
        eventConnection = nil
        lifecycleLock.unlock()
    }

    func startDaemon() {
        runLaunchctl(
            args: ["kickstart", "-k", launchTarget],
            pendingMessage: "Starting daemon...",
            successMessage: "Daemon start requested"
        )
    }

    func stopDaemon() {
        runLaunchctl(
            args: ["bootout", launchTarget],
            pendingMessage: "Stopping daemon...",
            successMessage: "Daemon stop requested"
        )
    }

    func quit() {
        stopEventLoop()
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
    }

    private func runEventLoop() {
        let backoffSchedule: [TimeInterval] = [0.2, 0.5, 1.0, 2.0, 5.0]
        var backoffIndex = 0

        while true {
            if isStopping() {
                return
            }

            publishConnectionStatus(.connecting, message: "Connecting to daemon...")

            do {
                let state = try transport.getState()
                let config = try transport.getConfig()
                publishState(state)
                publishConfig(config)

                let subscribeFrom = currentLastSeenSeq()
                let connection = try transport.subscribe(
                    fromSeq: subscribeFrom == 0 ? nil : subscribeFrom
                )

                lifecycleLock.lock()
                eventConnection = connection
                lifecycleLock.unlock()

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
                    message: "Disconnected. Reconnecting..."
                )

                let sleepDuration = backoffSchedule[min(backoffIndex, backoffSchedule.count - 1)]
                Thread.sleep(forTimeInterval: sleepDuration)
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
                self.runtimeState = state
                self.lastErrorCode = event.data["last_error"] as? String
            }
        }
    }

    private func sendCommand(
        method: String,
        params: [String: Any],
        pendingMessage: String,
        successMessage: String
    ) {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = pendingMessage
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                _ = try self.transport.request(method: method, params: params)
                let state = try self.transport.getState()
                let config = try self.transport.getConfig()

                DispatchQueue.main.async {
                    self.publishState(state)
                    self.publishConfig(config)
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

    private func updateConfig(
        params: [String: Any],
        pendingMessage: String,
        successMessage: String
    ) {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = pendingMessage
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                _ = try self.transport.request(method: "set_config", params: params)
                let config = try self.transport.getConfig()
                DispatchQueue.main.async {
                    self.publishConfig(config)
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

    private func publishState(_ snapshot: DaemonStateSnapshot) {
        DispatchQueue.main.async {
            self.runtimeState = snapshot.state
            self.lastErrorCode = snapshot.lastError
            self.eventSequence = max(self.eventSequence, snapshot.eventSeq)
            self.updateLastSeenSeq(snapshot.eventSeq)
        }
    }

    private func publishConfig(_ snapshot: DaemonConfigSnapshot) {
        DispatchQueue.main.async {
            self.toggleHotkey = HotkeyOption.fromRawOrDefault(snapshot.toggleHotkey)
            self.holdHotkey = HotkeyOption.fromRawOrDefault(snapshot.holdHotkey)
            self.model = ModelOption.fromRawOrDefault(snapshot.model)
            self.outputMode = OutputModeOption.fromRawOrDefault(snapshot.outputMode)
            self.maxRecordingSeconds = snapshot.maxRecordingSeconds
            self.configRevision = snapshot.revision
        }
    }

    private func publishConnectionStatus(_ status: ConnectionStatus, message: String) {
        DispatchQueue.main.async {
            self.connectionStatus = status
            self.statusMessage = message
        }
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
        if value > lastSeenSeq {
            lastSeenSeq = value
        }
        lifecycleLock.unlock()
    }

    private var launchTarget: String {
        "gui/\(getuid())/\(daemonLabel)"
    }

    private func runLaunchctl(
        args: [String],
        pendingMessage: String,
        successMessage: String
    ) {
        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = pendingMessage
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                _ = try runProcess(executable: "/bin/launchctl", arguments: args)
                DispatchQueue.main.async {
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
        if message.isEmpty {
            throw NSError(
                domain: "voico.launchctl",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "launchctl failed with code \(process.terminationStatus)"]
            )
        }

        throw NSError(
            domain: "voico.launchctl",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    return stdoutText
}
