import Darwin
import Foundation

enum IPCError: LocalizedError {
    case homeNotSet
    case socketPathTooLong
    case socketCreateFailed(String)
    case socketConnectFailed(String)
    case socketReadFailed(String)
    case socketWriteFailed(String)
    case connectionClosed
    case invalidEnvelope
    case handshakeFailed(String)
    case responseError(code: String, message: String)
    case missingResult
    case invalidStatePayload
    case invalidConfigPayload
    case invalidAPIKeyStatusPayload
    case responseTimedOut
    case subscribeTimedOut

    var errorDescription: String? {
        switch self {
        case .homeNotSet:
            return "HOME is not set"
        case .socketPathTooLong:
            return "Socket path is too long for unix domain socket"
        case let .socketCreateFailed(message):
            return "Could not create socket: \(message)"
        case let .socketConnectFailed(message):
            return "Could not connect to daemon socket: \(message)"
        case let .socketReadFailed(message):
            return "Could not read from daemon socket: \(message)"
        case let .socketWriteFailed(message):
            return "Could not write to daemon socket: \(message)"
        case .connectionClosed:
            return "Connection closed"
        case .invalidEnvelope:
            return "Invalid IPC envelope"
        case let .handshakeFailed(message):
            return "Handshake failed: \(message)"
        case let .responseError(code, message):
            return "\(message) (\(code))"
        case .missingResult:
            return "Daemon response is missing result payload"
        case .invalidStatePayload:
            return "State payload is invalid"
        case .invalidConfigPayload:
            return "Config payload is invalid"
        case .invalidAPIKeyStatusPayload:
            return "API key status payload is invalid"
        case .responseTimedOut:
            return "Timed out waiting for daemon response"
        case .subscribeTimedOut:
            return "Subscribe timed out waiting for daemon response"
        }
    }
}

enum ServerEnvelope {
    case helloOK
    case helloError(code: String, message: String)
    case response(id: String, ok: Bool, result: [String: Any]?, error: (String, String)?)
    case event(DaemonEventSnapshot)
}

final class IPCTransport {
    static let apiVersion = "1.0"
    private static let requestResponseTimeoutSeconds: TimeInterval = 5.0
    private static let subscribeResponseTimeoutSeconds: TimeInterval = 2.0
    private static let reachabilityTimeoutSeconds: TimeInterval = 0.15

    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    static func defaultSocketPath() throws -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw IPCError.homeNotSet
        }

        return NSString(string: "\(home)/Library/Application Support/voxa/run/daemon.sock")
            .expandingTildeInPath
    }

    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let connection = try IPCConnection.connect(socketPath: socketPath)
        defer { connection.close() }

        try connection.setReadTimeout(seconds: Self.requestResponseTimeoutSeconds)
        try connection.performHandshake(client: "voxa-menubar", clientVersion: "0.1.0")
        let requestId = UUID().uuidString
        try connection.sendRequest(id: requestId, method: method, params: params)

        while true {
            let envelope = try connection.readEnvelope()
            switch envelope {
            case let .response(id, ok, result, error) where id == requestId:
                if ok {
                    guard let result else {
                        throw IPCError.missingResult
                    }

                    return result
                }

                guard let error else {
                    throw IPCError.invalidEnvelope
                }

                throw IPCError.responseError(code: error.0, message: error.1)
            case .event:
                continue
            default:
                continue
            }
        }
    }

    func isReachable(timeout: TimeInterval = IPCTransport.reachabilityTimeoutSeconds) -> Bool {
        do {
            let connection = try IPCConnection.connect(socketPath: socketPath)
            defer { connection.close() }

            try connection.setReadTimeout(seconds: timeout)
            try connection.performHandshake(client: "voxa-menubar", clientVersion: "0.1.0")
            return true
        } catch {
            return false
        }
    }

    func getState() throws -> DaemonStateSnapshot {
        let result = try request(method: "get_state", params: [:])
        return try Self.parseStateSnapshot(result)
    }

    func getConfig() throws -> DaemonConfigSnapshot {
        let result = try request(method: "get_config", params: [:])
        return try Self.parseConfigSnapshot(result)
    }

    func getAPIKeyStatus() throws -> ApiKeyStatusSnapshot {
        let result = try request(method: "get_api_key_status", params: [:])
        return try Self.parseAPIKeyStatusSnapshot(result)
    }

    func setAPIKey(_ apiKey: String) throws {
        _ = try request(method: "set_api_key", params: ["api_key": apiKey])
    }

    func subscribe(fromSeq: UInt64?) throws -> IPCConnection {
        let connection = try IPCConnection.connect(socketPath: socketPath)

        do {
            try connection.performHandshake(client: "voxa-menubar", clientVersion: "0.1.0")
            let params: [String: Any] = {
                if let fromSeq {
                    return ["from_seq": fromSeq]
                }

                return [:]
            }()

            let requestId = UUID().uuidString
            try connection.sendRequest(id: requestId, method: "subscribe", params: params)
            try connection.setReadTimeout(seconds: Self.subscribeResponseTimeoutSeconds)
            defer { try? connection.setReadTimeout(seconds: nil) }

            while true {
                let envelope: ServerEnvelope
                do {
                    envelope = try connection.readEnvelope()
                } catch IPCError.responseTimedOut {
                    throw IPCError.subscribeTimedOut
                } catch {
                    throw error
                }
                switch envelope {
                case let .response(id, ok, _, error) where id == requestId:
                    if ok {
                        return connection
                    }

                    guard let error else {
                        throw IPCError.invalidEnvelope
                    }

                    throw IPCError.responseError(code: error.0, message: error.1)
                case .event:
                    continue
                default:
                    continue
                }
            }
        } catch {
            connection.close()
            throw error
        }
    }

    private static func parseStateSnapshot(_ payload: [String: Any]) throws -> DaemonStateSnapshot {
        guard let stateRaw = payload["state"] as? String,
              let state = RuntimeStateKind(rawValue: stateRaw)
        else {
            throw IPCError.invalidStatePayload
        }

        let eventSeq = numberToUInt64(payload["event_seq"])
        let lastError = payload["last_error"] as? String
        let recordingOrigin = payload["recording_origin"] as? String

        return DaemonStateSnapshot(
            state: state,
            eventSeq: eventSeq,
            lastError: lastError,
            recordingOrigin: recordingOrigin
        )
    }

    private static func parseConfigSnapshot(_ payload: [String: Any]) throws -> DaemonConfigSnapshot {
        guard let toggleHotkey = payload["toggle_hotkey"] as? String,
              let holdHotkey = payload["hold_hotkey"] as? String,
              let model = payload["model"] as? String,
              let outputMode = payload["output_mode"] as? String,
              let maxRecordingSeconds = payload["max_recording_seconds"] as? NSNumber,
              let revision = payload["revision"] as? NSNumber
        else {
            throw IPCError.invalidConfigPayload
        }

        return DaemonConfigSnapshot(
            toggleHotkey: toggleHotkey,
            holdHotkey: holdHotkey,
            model: model,
            outputMode: outputMode,
            maxRecordingSeconds: maxRecordingSeconds.uint64Value,
            revision: revision.uint64Value
        )
    }

    private static func parseAPIKeyStatusSnapshot(
        _ payload: [String: Any]
    ) throws -> ApiKeyStatusSnapshot {
        guard let source = payload["source"] as? String,
              let isSet = payload["is_set"] as? Bool
        else {
            throw IPCError.invalidAPIKeyStatusPayload
        }

        return ApiKeyStatusSnapshot(
            source: source,
            isSet: isSet,
            hint: payload["hint"] as? String
        )
    }

    private static func numberToUInt64(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else {
            return 0
        }

        return number.uint64Value
    }
}

final class IPCConnection {
    private let fileHandle: FileHandle
    private var inputBuffer = Data()

    private init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    static func connect(socketPath: String) throws -> IPCConnection {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        if descriptor < 0 {
            throw IPCError.socketCreateFailed(errnoMessage())
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathCString = socketPath.utf8CString
        let maxPathBytes = MemoryLayout.size(ofValue: address.sun_path)
        guard pathCString.count <= maxPathBytes else {
            Darwin.close(descriptor)
            throw IPCError.socketPathTooLong
        }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: CChar.self, repeating: 0)
            pathCString.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    descriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }

        if connectResult != 0 {
            let message = errnoMessage()
            Darwin.close(descriptor)
            throw IPCError.socketConnectFailed(message)
        }

        let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return IPCConnection(fileHandle: fileHandle)
    }

    func close() {
        try? fileHandle.close()
    }

    func setReadTimeout(seconds: TimeInterval?) throws {
        let timeout = seconds ?? 0
        let wholeSeconds = Int(timeout)
        let micros = Int((timeout - Double(wholeSeconds)) * 1_000_000)
        var timevalValue = timeval(tv_sec: wholeSeconds, tv_usec: Int32(micros))

        let result = withUnsafePointer(to: &timevalValue) { pointer in
            setsockopt(
                fileHandle.fileDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        if result != 0 {
            throw IPCError.socketConnectFailed(errnoMessage())
        }
    }

    func performHandshake(client: String, clientVersion: String) throws {
        try sendJSON([
            "type": "hello",
            "api_version": IPCTransport.apiVersion,
            "client": client,
            "client_version": clientVersion,
        ])

        let envelope = try readEnvelope()
        switch envelope {
        case .helloOK:
            return
        case let .helloError(code, message):
            throw IPCError.handshakeFailed("\(message) (\(code))")
        default:
            throw IPCError.invalidEnvelope
        }
    }

    func sendRequest(id: String, method: String, params: [String: Any]) throws {
        try sendJSON([
            "type": "request",
            "id": id,
            "method": method,
            "params": params,
        ])
    }

    func readEnvelope() throws -> ServerEnvelope {
        let object = try readJSONObject()
        guard let type = object["type"] as? String else {
            throw IPCError.invalidEnvelope
        }

        switch type {
        case "hello_ok":
            return .helloOK
        case "hello_error":
            guard let error = parseErrorPayload(object["error"]) else {
                throw IPCError.invalidEnvelope
            }
            return .helloError(code: error.0, message: error.1)
        case "response":
            guard let id = object["id"] as? String,
                  let ok = object["ok"] as? Bool
            else {
                throw IPCError.invalidEnvelope
            }

            let result = object["result"] as? [String: Any]
            let error = parseErrorPayload(object["error"])
            return .response(id: id, ok: ok, result: result, error: error)
        case "event":
            guard let name = object["name"] as? String,
                  let seqNumber = object["seq"] as? NSNumber
            else {
                throw IPCError.invalidEnvelope
            }

            let data = object["data"] as? [String: Any] ?? [:]
            return .event(DaemonEventSnapshot(name: name, seq: seqNumber.uint64Value, data: data))
        default:
            throw IPCError.invalidEnvelope
        }
    }

    private func sendJSON(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [])
        var framedPayload = payload
        framedPayload.append(0x0A)
        try writeAll(framedPayload)
    }

    private func readJSONObject() throws -> [String: Any] {
        while true {
            if let newlineIndex = inputBuffer.firstIndex(of: 0x0A) {
                let line = inputBuffer.prefix(upTo: newlineIndex)
                inputBuffer.removeSubrange(...newlineIndex)

                if line.isEmpty {
                    continue
                }

                let object = try JSONSerialization.jsonObject(with: Data(line), options: [])
                guard let dictionary = object as? [String: Any] else {
                    throw IPCError.invalidEnvelope
                }

                return dictionary
            }

            let chunk = try readChunk(maxBytes: 4096)
            if chunk.isEmpty {
                throw IPCError.connectionClosed
            }

            inputBuffer.append(chunk)
        }
    }

    private func parseErrorPayload(_ value: Any?) -> (String, String)? {
        guard let dictionary = value as? [String: Any],
              let code = dictionary["code"] as? String,
              let message = dictionary["message"] as? String
        else {
            return nil
        }

        return (code, message)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesWritten = 0
            while bytesWritten < data.count {
                let pointer = baseAddress.advanced(by: bytesWritten)
                let written = Darwin.write(
                    fileHandle.fileDescriptor,
                    pointer,
                    data.count - bytesWritten
                )

                if written < 0 {
                    throw IPCError.socketWriteFailed(errnoMessage())
                }

                bytesWritten += written
            }
        }
    }

    private func readChunk(maxBytes: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let bytesRead = Darwin.read(fileHandle.fileDescriptor, &buffer, maxBytes)

        if bytesRead == 0 {
            return Data()
        }

        if bytesRead < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw IPCError.responseTimedOut
            }
            throw IPCError.socketReadFailed(errnoMessage())
        }

        return Data(buffer.prefix(bytesRead))
    }
}

private func errnoMessage() -> String {
    String(cString: strerror(errno))
}
