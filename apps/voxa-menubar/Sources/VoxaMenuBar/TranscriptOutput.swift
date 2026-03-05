import Foundation

func processTranscriptOutput(
    text: String,
    mode: OutputModeOption,
    copyToClipboard: (String) -> Bool,
    sendAutopaste: () -> Bool
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
        guard copyToClipboard(text) else {
            return "Transcript ready but clipboard copy failed"
        }
        if sendAutopaste() {
            return "Transcript copied and pasted"
        }
        return "Transcript copied (autopaste failed)"
    }
}
