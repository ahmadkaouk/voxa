import Foundation

enum RecordingOrigin {
    case manual
    case hotkeyToggle
}

/// The service that receives dictation audio. English feedback and practice checks always use OpenAI.
enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI, mistral

    var id: String { rawValue }
    var name: String { self == .openAI ? "OpenAI" : "Mistral" }
    var environmentVariable: String { self == .openAI ? "OPENAI_API_KEY" : "MISTRAL_API_KEY" }
}

enum ModelOption: String, CaseIterable, Identifiable, Sendable {
    case gptTranscribe = "gpt-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case voxtralSmallTranscribe = "voxtral-small-transcribe-3-0"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gptTranscribe:
            return "GPT-Transcribe"
        case .gpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe"
        case .voxtralSmallTranscribe:
            return "Voxtral Small Transcribe 3 (Mistral)"
        }
    }

    var provider: TranscriptionProvider {
        switch self {
        case .gptTranscribe, .gpt4oMiniTranscribe: return .openAI
        case .voxtralSmallTranscribe: return .mistral
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
