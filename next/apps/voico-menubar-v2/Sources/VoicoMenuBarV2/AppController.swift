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
    private let hotkeyBridge = GlobalHotkeyBridge()
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
        autoStartDaemonOnLaunch()
        startEventLoop()
    }

    deinit {
        hotkeyBridge.stop()
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

    private func handleToggleHotkeyActivated() {
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
                let refreshedState = try self.transport.getState()
                DispatchQueue.main.async {
                    self.publishState(refreshedState)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleHoldHotkeyActivated() {
        sendHotkeyCommand(
            method: "start_recording",
            params: ["origin": "hotkey_hold"]
        )
    }

    private func handleHoldHotkeyDeactivated() {
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
                let state = try self.transport.getState()
                DispatchQueue.main.async {
                    self.publishState(state)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = error.localizedDescription
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
            self.hotkeyBridge.updateBindings(toggle: self.toggleHotkey, hold: self.holdHotkey)
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
        return "\(home)/Library/Logs/voico-v2"
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

        launchDaemonWithLaunchctl()
        if waitForDaemonAvailability(timeout: 1.2) {
            return
        }

        guard let daemonPath = resolveDaemonExecutablePath() else {
            throw NSError(
                domain: "voico.daemon",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve voico-daemon executable path for LaunchAgent installation"]
            )
        }

        try ensureLaunchAgentInstalled(daemonPath: daemonPath)
        launchDaemonWithLaunchctl()
        if waitForDaemonAvailability(timeout: 1.2) {
            return
        }

        throw NSError(
            domain: "voico.daemon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to start voico-daemon via launchd"]
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

    private func launchDaemonWithLaunchctl() {
        _ = try? runProcess(executable: "/bin/launchctl", arguments: ["kickstart", "-k", launchTarget])
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
          <key>KeepAlive</key>
          <true/>
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
