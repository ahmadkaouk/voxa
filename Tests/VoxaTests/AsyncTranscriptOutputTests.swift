#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AppKit
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

private final class OutputTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ event: String) { lock.lock(); items.append(event); lock.unlock() }
}

@MainActor
enum AsyncTranscriptOutputChecks {
    static func outcomes() async throws {
        let trace = OutputTrace()
        let output = TranscriptOutput(copy: { text in trace.add("copy: \(text)"); return false }, paste: { text, _, _, _ in
            trace.add("paste: \(text)"); return .snapshotFailed
        })
        try unitEqual(await output.deliver(" \n", mode: .clipboardAutopaste), .empty)
        try unitEqual(await output.deliver("hello", mode: .none), .disabled)
        try unitEqual(trace.events, [])
        try unitEqual(await output.copy("hello"), .copyFailed)
        try unitEqual(await output.deliver("hello", mode: .clipboardAutopaste), .paste(.snapshotFailed))
        try unitEqual(trace.events, ["copy: hello", "paste: hello"])
        let copying = TranscriptOutput(copy: { text in trace.add("copy: \(text)"); return true })
        try unitEqual(await copying.deliver(" hello\n", mode: .clipboardOnly), .copied)
        try unitExpect(!TranscriptOutputOutcome.copied.showsCompletion)
        try unitExpect(TranscriptOutputOutcome.disabled.showsCompletion)
        try unitEqual(trace.events, ["copy: hello", "paste: hello", "copy:  hello\n"])
        for result: ClipboardPasteResult in [.restored, .submitted, .submitSkipped, .manualPaste, .unconfirmed, .clipboardChanged, .snapshotFailed, .writeFailed, .restoreFailed] {
            let output = TranscriptOutput(paste: { _, _, _, _ in result })
            let outcome = await output.deliver("text", mode: .clipboardAutopaste)
            try unitEqual(outcome, .paste(result))
            try unitExpect(!outcome.showsCompletion)
            try unitEqual(outcome.isFailure, [.snapshotFailed, .writeFailed, .restoreFailed].contains(result))
        }
        await output.drain()
    }

    static func serializedCopyAndCleanup() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("Original clipboard", forType: .string)
        let trace = OutputTrace()
        let release = DispatchSemaphore(value: 0)
        let output = TranscriptOutput(copy: { text in
            trace.add(Thread.isMainThread ? "WRONG THREAD" : "copy")
            return onPasteboardThread { board.clearContents(); return board.setString(text, forType: .string) }
        }, paste: { text, _, _, onRead in
            let original = ClipboardSnapshot(pasteboard: board)!
            let result = ClipboardAutopaster(pasteboard: board, readTimeout: 0.2, settlingDelay: 0.02).paste(text, onRead: {
                onRead()
                if text == "Dictation", release.wait(timeout: .now() + 5) != .success { trace.add("TIMED OUT") }
            }) { _ in
                _ = onPasteboardThread { board.string(forType: .string) }
                trace.add(Thread.isMainThread ? "WRONG THREAD" : "paste: \(text)")
                return true
            }
            trace.add(ClipboardSnapshot(pasteboard: board)?.items == original.items ? "restored: \(text)" : "NOT RESTORED")
            return result
        })
        let delivery = Task {
            await output.deliver("Dictation", mode: .clipboardAutopaste, onPasteRead: {
                trace.add(Thread.isMainThread ? "ready" : "WRONG THREAD")
            })
        }
        try await eventually { trace.events == ["paste: Dictation", "ready"] }
        try unitEqual(board.string(forType: .string), "Dictation") // Readiness does not restore early.
        var copyRequested = false, secondRequested = false, drained = false
        let copy = Task { copyRequested = true; return await output.copy("Last transcript") }
        try await eventually { copyRequested }
        let second = Task { secondRequested = true; return await output.deliver("Second dictation", mode: .clipboardAutopaste) }
        try await eventually { secondRequested }
        let drain = Task { await output.drain(); drained = true }
        await Task.yield()
        try unitExpect(!drained)
        delivery.cancel() // cleanup must still finish before the queued copy and shutdown barrier
        try unitEqual(trace.events, ["paste: Dictation", "ready"])
        release.signal()
        try unitEqual(await delivery.value, .paste(.restored))
        try unitEqual(await copy.value, .copied)
        try unitEqual(await second.value, .paste(.restored))
        await drain.value
        try unitEqual(trace.events, ["paste: Dictation", "ready", "restored: Dictation", "copy",
                                     "paste: Second dictation", "restored: Second dictation"])
        try unitEqual(board.string(forType: .string), "Last transcript")
        try unitExpect(drained)
    }

    static func submissionTarget() async throws {
        let trace = OutputTrace()
        let output = TranscriptOutput(paste: { _, target, submit, _ in
            trace.add("\(target ?? -1):\(submit)")
            return submit ? .submitted : .restored
        })
        try unitEqual(await output.deliver("text", mode: .clipboardAutopaste, submitTo: 123), .paste(.submitted))
        try unitEqual(trace.events, ["123:true"])
        _ = await output.deliver("text", mode: .clipboardAutopaste)
        try unitExpect(trace.events.last?.hasSuffix(":false") == true)
        _ = await output.deliver("text", mode: .none, submitTo: 123)
        try unitEqual(trace.events.count, 2)
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("output: submission target and intent stay per delivery", submissionTarget),
        ("output: explicit outcomes and success/fallback distinctions", outcomes),
        ("output: early readiness, ordered paste/copy, and cleanup on cancellation", serializedCopyAndCleanup),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class AsyncTranscriptOutputTests: XCTestCase {
    func testSubmissionTarget() async throws { try await AsyncTranscriptOutputChecks.submissionTarget() }
    func testOutcomes() async throws { try await AsyncTranscriptOutputChecks.outcomes() }
    func testSerializedCopyAndCleanup() async throws { try await AsyncTranscriptOutputChecks.serializedCopyAndCleanup() }
}
#endif
#endif
