import Foundation

enum RecordingOrigin {
    case manual
    case hotkeyToggle
}

enum ModelOption: String, CaseIterable, Identifiable {
    case gptTranscribe = "gpt-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gptTranscribe:
            return "GPT-Transcribe"
        case .gpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe"
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
