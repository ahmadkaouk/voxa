import AppKit
import Foundation

final class AppController: ObservableObject {
    @Published private(set) var connectionStatus: ConnectionStatus = .connecting
    @Published private(set) var runtimeState: RuntimeStateKind = .idle
    @Published private(set) var lastEventName: String = "none"
    @Published private(set) var lastErrorCode: String?
    @Published private(set) var statusMessage: String = "Starting daemon connection..."
    @Published private(set) var isBusy = false
    @Published private(set) var eventSequence: UInt64 = 0
    @Published private(set) var socketPath: String

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

    func reconnectNow() {
        lifecycleLock.lock()
        eventConnection?.close()
        eventConnection = nil
        lifecycleLock.unlock()
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
                let snapshot = try transport.getState()
                publishState(snapshot)

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
                let snapshot = try self.transport.getState()

                DispatchQueue.main.async {
                    self.publishState(snapshot)
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
}
