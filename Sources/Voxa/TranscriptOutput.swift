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

    /// Normal paste and copy output need no confirmation bar.
    var showsCompletion: Bool {
        switch self {
        case .disabled: return true
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
    private let pasteText: (String, pid_t?, Bool, () -> Void) -> ClipboardPasteResult

    init(copy: @escaping (String) -> Bool = { text in
        onPasteboardThread {
            let board = NSPasteboard.general
            board.clearContents()
            return board.setString(text, forType: .string)
        }
    }, paste: @escaping (String, pid_t?, Bool, () -> Void) -> ClipboardPasteResult = { text, target, submit, onRead in
        let board = onPasteboardThread { NSPasteboard.general }
        let sendReturn: ((Int) -> Bool)? = submit ? { ownedCount in
            guard let target else { return false }
            return sendSubmitReturn(to: target, clipboardChangeCount: ownedCount)
        } : nil
        return ClipboardAutopaster(pasteboard: board).paste(text, onRead: onRead, sendReturn: sendReturn) { ownedCount in
            guard let target, target != getpid() else { return false }
            return sendPasteShortcut(to: target, clipboardChangeCount: ownedCount)
        }
    }) {
        copyText = copy
        pasteText = paste
    }

    /// The read callback permits another recording; the result still waits for clipboard cleanup.
    @MainActor
    func deliver(_ text: String, mode: OutputModeOption, submitTo: pid_t? = nil,
                 onPasteRead: @escaping @MainActor @Sendable () -> Void = {}) async -> TranscriptOutputOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let target = mode == .clipboardAutopaste ? (submitTo ?? NSWorkspace.shared.frontmostApplication?.processIdentifier) : nil
        return await withCheckedContinuation { continuation in
            worker.async {
                let outcome: TranscriptOutputOutcome
                switch mode {
                case .none: outcome = .disabled
                case .clipboardOnly: outcome = self.copyText(text) ? .copied : .copyFailed
                case .clipboardAutopaste:
                    outcome = .paste(self.pasteText(text, target, submitTo != nil) {
                        DispatchQueue.main.async { onPasteRead() }
                    })
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
