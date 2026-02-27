import Foundation

enum RuntimeStateKind: String {
    case idle
    case recording
    case transcribing
    case outputting
    case error

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .outputting:
            return "Outputting"
        case .error:
            return "Error"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle:
            return "mic"
        case .recording:
            return "waveform"
        case .transcribing:
            return "waveform.and.mic"
        case .outputting:
            return "square.and.arrow.up"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var isListeningActive: Bool {
        self == .recording || self == .transcribing
    }
}

enum ConnectionStatus {
    case connecting
    case connected
    case disconnected(message: String)

    var label: String {
        switch self {
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case let .disconnected(message):
            return "Disconnected: \(message)"
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }

        return false
    }
}

struct DaemonStateSnapshot {
    let state: RuntimeStateKind
    let eventSeq: UInt64
    let lastError: String?
    let recordingOrigin: String?
}

struct DaemonEventSnapshot {
    let name: String
    let seq: UInt64
    let data: [String: Any]
}
