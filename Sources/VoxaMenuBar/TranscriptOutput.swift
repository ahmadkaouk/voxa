import Foundation
import AppKit

enum TranscriptOutputOutcome: Equatable {
    case empty, disabled, copied, copyFailed
    case paste(ClipboardPasteResult)

    var isFailure: Bool {
        switch self {
        case .empty, .copyFailed, .paste(.snapshotFailed), .paste(.writeFailed), .paste(.restoreFailed): return true
        default: return false
        }
    }

    /// Fallbacks and a newer clipboard are useful outcomes, but must not show a success checkmark.
    var showsSuccess: Bool {
        switch self {
        case .disabled, .copied, .paste(.restored): return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .empty: return "No speech was detected."
        case .disabled: return "Transcript ready (output disabled)"
        case .copied: return "Transcript copied to clipboard"
        case .copyFailed: return "Clipboard copy failed; use Copy Last Transcript"
        case .paste(.restored): return "Paste requested; previous clipboard restored"
        case .paste(let result): return result.message
        }
    }
}

/// Synchronous clipboard operations are owned by one queue. Main-actor entry points enqueue in
/// command order, including Copy Last Transcript; cancellation never abandons clipboard cleanup.
final class TranscriptOutput: @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.voxa.transcript-output", qos: .userInitiated)
    private let copyText: (String) -> Bool
    private let pasteText: (String, pid_t?) -> ClipboardPasteResult

    init(copy: @escaping (String) -> Bool = { text in
        onPasteboardThread {
            let board = NSPasteboard.general
            board.clearContents()
            return board.setString(text, forType: .string)
        }
    }, paste: @escaping (String, pid_t?) -> ClipboardPasteResult = { text, target in
        let board = onPasteboardThread { NSPasteboard.general }
        return ClipboardAutopaster(pasteboard: board).paste(text) { ownedCount in
            guard let target, target != getpid() else { return false }
            return sendPasteShortcut(to: target, clipboardChangeCount: ownedCount)
        }
    }) {
        copyText = copy
        pasteText = paste
    }

    @MainActor
    func deliver(_ text: String, mode: OutputModeOption) async -> TranscriptOutputOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let target = mode == .clipboardAutopaste ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        return await withCheckedContinuation { continuation in
            worker.async {
                let outcome: TranscriptOutputOutcome
                switch mode {
                case .none: outcome = .disabled
                case .clipboardOnly: outcome = self.copyText(text) ? .copied : .copyFailed
                case .clipboardAutopaste: outcome = .paste(self.pasteText(text, target))
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    @MainActor
    func copy(_ text: String) async -> TranscriptOutputOutcome { await deliver(text, mode: .clipboardOnly) }

    @MainActor
    func drain() async {
        await withCheckedContinuation { continuation in worker.async { continuation.resume() } }
    }
}
