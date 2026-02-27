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
    @Published private(set) var apiKeySource: String = "keychain"
    @Published private(set) var isAPIKeySet = false
    @Published var apiKeyInput = ""

    private let transport: IPCTransport
    private let eventQueue = DispatchQueue(label: "voico.v2.menubar.events", qos: .userInitiated)
    private let requestQueue = DispatchQueue(label: "voico.v2.menubar.requests", qos: .userInitiated)

    private let lifecycleLock = NSLock()
    private var shouldStop = false
    private var lastSeenSeq: UInt64 = 0
    private var eventConnection: IPCConnection?
    private var managedDaemonProcess: Process?

    init() {
        let path: String
        do {
            path = try IPCTransport.defaultSocketPath()
        } catch {
            path = "/tmp/voico-v2-daemon.sock"
        }

        socketPath = path
        transport = IPCTransport(socketPath: path)
        autoStartDaemonOnLaunch()
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

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            statusMessage = "API key cannot be empty"
            return
        }

        DispatchQueue.main.async {
            self.isBusy = true
            self.statusMessage = "Saving API key..."
        }

        requestQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.transport.setAPIKey(trimmed)
                let status = try self.transport.getAPIKeyStatus()
                DispatchQueue.main.async {
                    self.publishAPIKeyStatus(status)
                    self.statusMessage = "API key saved"
                    self.apiKeyInput = ""
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

    func reconnectNow() {
        lifecycleLock.lock()
        eventConnection?.close()
        eventConnection = nil
        lifecycleLock.unlock()
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

            var stopped = false
            if self.stopManagedDaemonIfNeeded() {
                stopped = true
            }

            if (try? runProcess(executable: "/bin/launchctl", arguments: ["bootout", self.launchTarget])) != nil {
                stopped = true
            }

            DispatchQueue.main.async {
                self.statusMessage = stopped
                    ? "Daemon stop requested"
                    : "No managed daemon process found to stop"
                self.isBusy = false
            }
        }
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
                let apiKeyStatus = try transport.getAPIKeyStatus()
                publishState(state)
                publishConfig(config)
                publishAPIKeyStatus(apiKeyStatus)

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
                let apiKeyStatus = try self.transport.getAPIKeyStatus()

                DispatchQueue.main.async {
                    self.publishState(state)
                    self.publishConfig(config)
                    self.publishAPIKeyStatus(apiKeyStatus)
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
                let apiKeyStatus = try self.transport.getAPIKeyStatus()
                DispatchQueue.main.async {
                    self.publishConfig(config)
                    self.publishAPIKeyStatus(apiKeyStatus)
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

    private func publishAPIKeyStatus(_ snapshot: ApiKeyStatusSnapshot) {
        DispatchQueue.main.async {
            self.apiKeySource = snapshot.source
            self.isAPIKeySet = snapshot.isSet
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

    private func autoStartDaemonOnLaunch() {
        requestQueue.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDaemonRunning()
        }
    }

    private func ensureDaemonRunning() throws {
        if daemonIsReachable() {
            return
        }

        try launchDaemonWithLaunchctl()
        if waitForDaemonAvailability(timeout: 1.2) {
            return
        }

        try launchDaemonDirectly()
        if waitForDaemonAvailability(timeout: 2.0) {
            return
        }

        throw NSError(
            domain: "voico.daemon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to start voico-daemon"]
        )
    }

    private func daemonIsReachable() -> Bool {
        (try? transport.getState()) != nil
    }

    private func waitForDaemonAvailability(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if daemonIsReachable() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func launchDaemonWithLaunchctl() throws {
        do {
            _ = try runProcess(executable: "/bin/launchctl", arguments: ["kickstart", "-k", launchTarget])
        } catch {
            // If launch service is not installed, direct spawn fallback will handle startup.
        }
    }

    private func launchDaemonDirectly() throws {
        if let process = managedDaemonProcess, process.isRunning {
            return
        }

        guard let daemonPath = resolveDaemonExecutablePath() else {
            throw NSError(
                domain: "voico.daemon",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve voico-daemon executable path"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        managedDaemonProcess = process
    }

    private func stopManagedDaemonIfNeeded() -> Bool {
        guard let process = managedDaemonProcess else {
            return false
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        managedDaemonProcess = nil
        return true
    }

    private func resolveDaemonExecutablePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let override = env["VOICO_DAEMON_BIN"], !override.isEmpty {
            candidates.append(override)
        }

        if let pathEnv = env["PATH"] {
            for entry in pathEnv.split(separator: ":") {
                candidates.append("\(entry)/voico-daemon")
            }
        }

        candidates.append("~/.cargo/bin/voico-daemon")
        candidates.append("/opt/homebrew/bin/voico-daemon")
        candidates.append("/usr/local/bin/voico-daemon")

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(
            cwd
                .appendingPathComponent("../../target/debug/voico-daemon")
                .standardizedFileURL
                .path
        )
        candidates.append(
            cwd
                .appendingPathComponent("../target/debug/voico-daemon")
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
                domain: "voico.process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Command failed (\(process.terminationStatus)): \(command)"]
            )
        }

        throw NSError(
            domain: "voico.process",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    return stdoutText
}
