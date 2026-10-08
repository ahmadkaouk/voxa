import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func onPasteboardThread<T>(_ operation: () -> T) -> T {
    if Thread.isMainThread { return operation() }
    return DispatchQueue.main.sync(execute: operation)
}

/// Materialize every representation before replacing the pasteboard. Retaining
/// NSPasteboardItems themselves does not work: they become stale on ownership change.
struct ClipboardSnapshot {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    init?(pasteboard: NSPasteboard) {
        let captured: (Int, [[NSPasteboard.PasteboardType: Data]])? = onPasteboardThread {
            let originalCount = pasteboard.changeCount
            var savedItems: [[NSPasteboard.PasteboardType: Data]] = []
            guard let sourceItems = pasteboard.pasteboardItems else { return nil }
            for item in sourceItems {
                var representations: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    representations[type] = data
                }
                guard !representations.isEmpty else { return nil }
                savedItems.append(representations)
            }
            guard pasteboard.changeCount == originalCount else { return nil }
            return (originalCount, savedItems)
        }
        guard let captured else { return nil }
        changeCount = captured.0
        items = captured.1
    }

    func restore(to pasteboard: NSPasteboard, ifUnchangedSince expectedCount: Int) -> Bool {
        onPasteboardThread {
            let restoredItems = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            guard pasteboard.changeCount == expectedCount else { return false }
            pasteboard.clearContents()
            return restoredItems.isEmpty || pasteboard.writeObjects(restoredItems)
        }
    }
}

enum ClipboardPasteResult: Equatable {
    case restored
    case submitted
    case submitSkipped
    case manualPaste
    case unconfirmed
    case clipboardChanged
    case snapshotFailed
    case writeFailed
    case restoreFailed

    var message: String {
        switch self {
        case .restored:
            return "Transcript pasted; previous clipboard restored"
        case .submitted:
            return "Transcript pasted"
        case .submitSkipped:
            return "Transcript pasted; send manually"
        case .manualPaste:
            return "Transcript copied; press ⌘V to paste"
        case .unconfirmed:
            return "Paste not confirmed; transcript kept on clipboard"
        case .clipboardChanged:
            return "Clipboard changed; your newer copy was kept"
        case .snapshotFailed:
            return "Clipboard could not be saved; use Copy Last Transcript"
        case .writeFailed:
            return "Clipboard copy failed; use Copy Last Transcript"
        case .restoreFailed:
            return "Paste sent; previous clipboard could not be restored"
        }
    }
}

/// Run complete output operations on the same serial queue, never the main thread.
/// A lazy text provider lets us wait for a clipboard read instead of restoring on
/// a blind timer. macOS does not identify the reader or acknowledge text insertion;
/// the read plus a settling interval is a best-effort delivery signal.
final class ClipboardAutopaster {
    private let pasteboard: NSPasteboard
    private let readTimeout: TimeInterval
    private let settlingDelay: TimeInterval

    init(
        pasteboard: NSPasteboard = .general,
        readTimeout: TimeInterval = 2,
        settlingDelay: TimeInterval = 0.5
    ) {
        self.pasteboard = pasteboard
        self.readTimeout = readTimeout
        self.settlingDelay = settlingDelay
    }

    func paste(_ text: String, onRead: () -> Void = {}, sendReturn: ((Int) -> Bool)? = nil, sendShortcut: (Int) -> Bool) -> ClipboardPasteResult {
        precondition(!Thread.isMainThread, "Paste delivery waits must not block the main run loop")
        guard let snapshot = ClipboardSnapshot(pasteboard: pasteboard) else {
            return .snapshotFailed
        }

        let provider = TranscriptPasteboardProvider(text: text)
        let item = NSPasteboardItem()
        var ownedCount = 0
        let preparationError: ClipboardPasteResult? = onPasteboardThread {
            guard item.setDataProvider(provider, forTypes: [.string]) else { return .writeFailed }
            // A conventional marker asks clipboard managers to skip temporary text.
            item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
            guard pasteboard.changeCount == snapshot.changeCount else { return .clipboardChanged }
            let clearedCount = pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                _ = snapshot.restore(to: pasteboard, ifUnchangedSince: clearedCount)
                return .writeFailed
            }
            ownedCount = pasteboard.changeCount
            return nil
        }
        if let preparationError { return preparationError }
        func stillOwnsClipboard() -> Bool {
            onPasteboardThread { pasteboard.changeCount == ownedCount }
        }
        func retainForManualPaste() {
            onPasteboardThread {
                if pasteboard.changeCount == ownedCount {
                    item.setString(text, forType: .string)
                }
            }
        }

        provider.beginPaste()
        let sent = sendShortcut(ownedCount)
        guard stillOwnsClipboard() else { return .clipboardChanged }
        guard sent else {
            retainForManualPaste()
            return .manualPaste
        }

        let deadline = ProcessInfo.processInfo.systemUptime + readTimeout
        while !provider.wasReadDuringPaste && ProcessInfo.processInfo.systemUptime < deadline {
            guard stillOwnsClipboard() else { return .clipboardChanged }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard stillOwnsClipboard() else { return .clipboardChanged }
        guard provider.wasReadDuringPaste else {
            // Materialize the transcript so manual paste still works after this
            // operation releases its data provider. Keep the old snapshot private.
            retainForManualPaste()
            return .unconfirmed
        }

        // Capture may start again now; this queue still owns the entire restoration operation.
        onRead()
        Thread.sleep(forTimeInterval: settlingDelay)
        guard stillOwnsClipboard() else { return .clipboardChanged }
        let submitted = sendReturn?(ownedCount)
        guard stillOwnsClipboard() else { return .clipboardChanged }
        guard snapshot.restore(to: pasteboard, ifUnchangedSince: ownedCount) else { return .restoreFailed }
        if let submitted { return submitted ? .submitted : .submitSkipped }
        return .restored
    }
}

private final class TranscriptPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let lock = NSLock()
    private var pasteBegan = false
    private var readDuringPaste = false

    init(text: String) {
        self.text = text
    }

    func beginPaste() {
        lock.lock()
        pasteBegan = true
        lock.unlock()
    }

    var wasReadDuringPaste: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readDuringPaste
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string else { return }
        let supplied = item.setString(text, forType: type)
        lock.lock()
        if pasteBegan && supplied {
            readDuringPaste = true
        }
        lock.unlock()
    }
}

func sendPasteShortcut(to targetPID: pid_t, clipboardChangeCount: Int) -> Bool {
    let vKey: CGKeyCode = 9
    let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    let deadline = ProcessInfo.processInfo.systemUptime + 1.5
    while !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
        guard ProcessInfo.processInfo.systemUptime < deadline,
              onPasteboardThread({ NSPasteboard.general.changeCount == clipboardChangeCount })
        else { return false }
        Thread.sleep(forTimeInterval: 0.02)
    }

    guard AXIsProcessTrusted(),
          onPasteboardThread({ NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
              && NSPasteboard.general.changeCount == clipboardChangeCount }),
          let source = CGEventSource(stateID: .privateState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else { return false }

    // Command flags on the V events are sufficient. Avoid synthetic Command
    // key-down/up events, and direct the pair to the checked destination app.
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.postToPid(targetPID)
    keyUp.postToPid(targetPID)
    return true
}

/// Send Return only to the app that received the paste, after the paste settling interval.
func sendSubmitReturn(to targetPID: pid_t, clipboardChangeCount: Int) -> Bool {
    let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    let deadline = ProcessInfo.processInfo.systemUptime + 1.5
    while !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
        || CGEventSource.keyState(.combinedSessionState, key: 36)
        || CGEventSource.keyState(.combinedSessionState, key: 76) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return onPasteboardThread {
        guard AXIsProcessTrusted(), targetPID != getpid(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              NSPasteboard.general.changeCount == clipboardChangeCount,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return false }
        down.flags = []; up.flags = []
        down.postToPid(targetPID); up.postToPid(targetPID)
        return true
    }
}
