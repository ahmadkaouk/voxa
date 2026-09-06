import Foundation

func processTranscriptOutput(
    text: String,
    mode: OutputModeOption,
    copyToClipboard: (String) -> Bool,
    autopaste: (String) -> String
) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "Transcript ready (empty)"
    }

    switch mode {
    case .none:
        return "Transcript ready (output disabled)"
    case .clipboardOnly:
        if copyToClipboard(text) {
            return "Transcript copied to clipboard"
        }
        return "Transcript ready but clipboard copy failed"
    case .clipboardAutopaste:
        // The paste operation owns its temporary clipboard and restoration.
        // Writing here first would destroy the clipboard we need to preserve.
        return autopaste(text)
    }
}
