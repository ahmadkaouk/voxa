#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AppKit
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

private struct OutputCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw OutputCheckFailure(description: message) }
}

private enum OutputChecks {
    static func withPasteboard(_ body: (NSPasteboard) throws -> Void) throws {
        let board = onPasteboardThread { NSPasteboard.withUniqueName() }
        defer { onPasteboardThread { board.releaseGlobally() } }
        _ = onPasteboardThread { board.clearContents() }
        try body(board)
    }

    static func put(_ text: String, on board: NSPasteboard) {
        onPasteboardThread {
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    static func richClipboard() throws {
        try withPasteboard { board in
            let first = NSPasteboardItem()
            first.setString("Original formatted text", forType: .string)
            first.setData(Data("{\\rtf1 Original formatted text}".utf8), forType: .rtf)
            first.setData(Data([0x89, 0x50, 0x4e, 0x47, 0, 255]), forType: .png)
            let second = NSPasteboardItem()
            second.setString("file:///tmp/voxa-test.txt", forType: .fileURL)
            try expect(onPasteboardThread { board.writeObjects([first, second]) }, "Fixture must be writable")
            let original = ClipboardSnapshot(pasteboard: board)!
            var reads = 0
            let result = ClipboardAutopaster(pasteboard: board, readTimeout: 0.3, settlingDelay: 0.02).paste("New dictation", onRead: {
                if onPasteboardThread({ board.string(forType: .string) }) == "New dictation" { reads += 1 }
            }) { _ in
                onPasteboardThread { board.string(forType: .string) } == "New dictation"
            }
            try expect(reads == 1, "Readiness must be reported once, before the original clipboard is restored")
            try expect(result == .restored, "Consumed paste must restore clipboard: \(result)")
            try expect(ClipboardSnapshot(pasteboard: board)?.items == original.items, "Every item and representation must round trip")
        }
    }

    static func emptyClipboard() throws {
        try withPasteboard { board in
            let result = ClipboardAutopaster(pasteboard: board, readTimeout: 0.3, settlingDelay: 0.02).paste("New dictation") { _ in
                onPasteboardThread { board.string(forType: .string) } == "New dictation"
            }
            try expect(result == .restored, "Empty original clipboard must also restore: \(result)")
            try expect(onPasteboardThread { board.pasteboardItems?.isEmpty == true }, "Original empty clipboard must remain empty")
        }
    }

    static func failedAndUnconfirmedPaste() throws {
        for sent in [false, true] {
            try withPasteboard { board in
                put("Original", on: board)
                var reads = 0
                let result = ClipboardAutopaster(pasteboard: board, readTimeout: 0.04, settlingDelay: 0.01).paste("Manual recovery", onRead: { reads += 1 }) { _ in sent }
                try expect(reads == 0, "Failed or unconsumed paste must not report early readiness")
                try expect(result == (sent ? .unconfirmed : .manualPaste), "Unconsumed text must be retained: \(result)")
                try expect(onPasteboardThread { board.string(forType: .string) } == "Manual recovery", "Manual paste must outlive the temporary provider")
            }
        }
    }

    static func newerCopy() throws {
        try withPasteboard { board in
            put("Original", on: board)
            var reads = 0
            let result = ClipboardAutopaster(pasteboard: board).paste("Dictation", onRead: { reads += 1 }) { _ in
                put("User copied something newer", on: board)
                return true
            }
            try expect(reads == 0, "An intervening clipboard owner must not report early readiness")
            try expect(result == .clipboardChanged, "Newer clipboard owner must be detected")
            try expect(onPasteboardThread { board.string(forType: .string) } == "User copied something newer", "Never overwrite a newer copy")
        }
    }

    static func newerCopyAfterRead() throws {
        try withPasteboard { board in
            put("Original", on: board)
            let replaced = DispatchSemaphore(value: 0)
            let result = ClipboardAutopaster(pasteboard: board, readTimeout: 0.3, settlingDelay: 0.15).paste("Dictation") { _ in
                _ = onPasteboardThread { board.string(forType: .string) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                    put("Newer copy during settling", on: board)
                    replaced.signal()
                }
                return true
            }
            try expect(replaced.wait(timeout: .now() + 1) == .success, "New copy must run")
            try expect(result == .clipboardChanged, "Clipboard ownership must be checked after settling")
            try expect(onPasteboardThread { board.string(forType: .string) } == "Newer copy during settling", "Restoration must not erase a copy made after paste")
        }
    }

    static func delayedConsumer() throws {
        try withPasteboard { board in
            put("Original", on: board)
            let consumed = DispatchSemaphore(value: 0)
            let result = ClipboardAutopaster(pasteboard: board, readTimeout: 0.6, settlingDelay: 0.02).paste("Delayed dictation") { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    if onPasteboardThread({ board.string(forType: .string) }) == "Delayed dictation" { consumed.signal() }
                }
                return true
            }
            try expect(consumed.wait(timeout: .now() + 1) == .success, "Slow consumer must receive the transcript, not the old clipboard")
            try expect(result == .restored, "Restore only after the delayed read: \(result)")
            try expect(onPasteboardThread { board.string(forType: .string) } == "Original", "Restore after delayed read")
        }
    }

    static func snapshotOwnership() throws {
        try withPasteboard { board in
            put("Original", on: board)
            let snapshot = ClipboardSnapshot(pasteboard: board)!
            put("Later", on: board)
            try expect(!snapshot.restore(to: board, ifUnchangedSince: snapshot.changeCount), "Stale snapshot must refuse restoration")
            try expect(onPasteboardThread { board.string(forType: .string) } == "Later", "Stale restoration must leave clipboard untouched")
        }
    }

    static let all: [(String, () throws -> Void)] = [
        ("rich clipboard with multiple items", richClipboard),
        ("empty clipboard", emptyClipboard),
        ("failed and unconfirmed paste", failedAndUnconfirmedPaste),
        ("newer copy", newerCopy),
        ("newer copy after read", newerCopyAfterRead),
        ("delayed consumer", delayedConsumer),
        ("snapshot ownership", snapshotOwnership),
    ]
}

#if VOXA_STANDALONE_TESTS
@main
private enum OutputChecksRunner {
    static func main() {
        // The pasteboard server delivers lazy-provider requests through the main
        // run loop; keep it running while tests exercise the production queue path.
        DispatchQueue.global().async {
            do {
                for (name, check) in OutputChecks.all {
                    try check()
                    print("PASS: \(name)")
                }
                print("All \(OutputChecks.all.count) output checks passed")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
#else
final class TranscriptOutputTests: XCTestCase {
    func testClipboardOutput() {
        let completed = expectation(description: "Clipboard output checks")
        DispatchQueue.global().async {
            for (name, check) in OutputChecks.all {
                do { try check() } catch { XCTFail("\(name): \(error)") }
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
    }
}
#endif
#endif
