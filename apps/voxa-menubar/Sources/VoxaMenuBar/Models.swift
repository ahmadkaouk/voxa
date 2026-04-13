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
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case gpt4oTranscribe = "gpt-4o-transcribe"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe"
        case .gpt4oTranscribe:
            return "GPT-4o Transcribe"
        }
    }

    static func fromRawOrDefault(_ raw: String) -> ModelOption {
        ModelOption(rawValue: raw) ?? .gpt4oMiniTranscribe
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
            return "Clipboard + Autopaste"
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
