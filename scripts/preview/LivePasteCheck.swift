import AppKit
import ApplicationServices
import Foundation

@main
struct LivePasteCheck {
    static func main() {
        guard AXIsProcessTrusted() else {
            fputs("SKIP: test process has no Accessibility access\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 540, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Voxa paste verification"
        let field = NSTextView(frame: window.contentView!.bounds)
        field.isRichText = false
        field.string = "Before [replace me] after"
        field.setSelectedRange(NSRange(location: 7, length: 12))
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        app.activate(ignoringOtherApps: true)
        let sample = "Voxa test: café 👋\nSecond line."
        let expected = "Before " + sample + " after"
        guard let original = ClipboardSnapshot(pasteboard: .general) else {
            fputs("FAIL: original clipboard could not be safely saved\n", stderr)
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            var ownedCount: Int?
            let result = ClipboardAutopaster().paste(sample) { count in
                ownedCount = count
                return sendPasteShortcut(to: getpid(), clipboardChangeCount: count)
            }
            let completedCount = ownedCount
            DispatchQueue.main.async {
                let inserted = field.string == expected
                let restored = ClipboardSnapshot(pasteboard: .general)?.items == original.items
                if !restored, let completedCount, NSPasteboard.general.changeCount == completedCount {
                    _ = original.restore(to: .general, ifUnchangedSince: completedCount)
                }
                print("Paste result: \(result)")
                print("Unicode, newline, and selection replacement: \(inserted ? "PASS" : "FAIL")")
                print("Original system clipboard restored: \(restored ? "PASS" : "FAIL")")
                window.orderOut(nil)
                previousApp?.activate(options: [])
                exit(inserted && restored && result == .restored ? 0 : 1)
            }
        }
        app.run()
    }
}
