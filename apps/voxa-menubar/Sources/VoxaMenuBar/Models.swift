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
            return "waveform"
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

enum RecordingOrigin: String {
    case manual = "manual"
    case hotkeyToggle = "hotkey_toggle"
    case hotkeyHold = "hotkey_hold"

    static func fromRaw(_ raw: String?) -> RecordingOrigin? {
        guard let raw else {
            return nil
        }

        return RecordingOrigin(rawValue: raw)
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

enum ModelOption: String, CaseIterable, Identifiable {
    case gptTranscribe = "gpt-transcribe"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gptTranscribe:
            return "GPT-Transcribe"
        }
    }

    static func fromRawOrDefault(_ raw: String) -> ModelOption {
        ModelOption(rawValue: raw) ?? .gptTranscribe
    }
}

enum OutputModeOption: String, CaseIterable, Identifiable {
    case clipboardAutopaste = "clipboard_autopaste"
    case clipboardOnly = "clipboard_only"
    case none = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clipboardAutopaste:
            return "Autopaste (Keep Clipboard)"
        case .clipboardOnly:
            return "Clipboard Only"
        case .none:
            return "None"
        }
    }

    static func fromRawOrDefault(_ raw: String) -> OutputModeOption {
        OutputModeOption(rawValue: raw) ?? .clipboardAutopaste
    }
}

struct DaemonStateSnapshot {
    let state: RuntimeStateKind
    let eventSeq: UInt64
    let lastError: String?
    let recordingOrigin: String?
}

struct DaemonConfigSnapshot {
    let toggleHotkey: String
    let holdHotkey: String
    let model: String
    let outputMode: String
    let maxRecordingSeconds: UInt64
    let revision: UInt64
}

struct ApiKeyStatusSnapshot {
    let source: String
    let isSet: Bool
    let hint: String?
}

struct DaemonEventSnapshot {
    let name: String
    let seq: UInt64
    let data: [String: Any]
}

enum PopoverPrimaryAction: Equatable {
    case addAPIKey
    case reconnect
    case connecting
    case startRecording
    case stopRecording
    case retry
    case working

    static func resolve(
        isAPIKeySet: Bool,
        connectionStatus: ConnectionStatus,
        runtimeState: RuntimeStateKind
    ) -> PopoverPrimaryAction {
        switch connectionStatus {
        case .connecting:
            return .connecting
        case .disconnected:
            return .reconnect
        case .connected:
            switch runtimeState {
            case .idle:
                return isAPIKeySet ? .startRecording : .addAPIKey
            case .recording:
                return .stopRecording
            case .error:
                return isAPIKeySet ? .retry : .addAPIKey
            case .transcribing, .outputting:
                return .working
            }
        }
    }
}
