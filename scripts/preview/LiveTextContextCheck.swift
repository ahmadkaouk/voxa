import AppKit
import ApplicationServices

/// Reads only this temporary app's synthetic window. No microphone, API, clipboard or foreign-app text.
@main
enum LiveTextContextCheck {
    @MainActor static func main() {
        guard AXIsProcessTrusted() else {
            fputs("SKIP: test process has no Accessibility access\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 650, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Voxa text-context verification"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        let message = NSTextField(labelWithString: "Could you explain the deployment issue?")
        message.frame = NSRect(x: 30, y: 240, width: 580, height: 40)
        content.addSubview(message)
        let field = NSTextView(frame: NSRect(x: 30, y: 40, width: 580, height: 120))
        field.isRichText = false
        field.string = "I was looking at the configuration."
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        content.addSubview(field)
        window.contentView = content
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let result = await Task.detached(priority: .utility) {
                let began = ProcessInfo.processInfo.systemUptime
                let context = ContextTextExtractor(reader: AXContextReader())
                    .capture(application: AXUIElementCreateApplication(getpid()), appName: "Fixture")
                return (context, ProcessInfo.processInfo.systemUptime - began)
            }.value
            let draft = result.0?.text.contains(field.string) == true
            let nearby = result.0?.text.contains(message.stringValue) == true
            let bounded = result.1 < 0.6
            print("Live focused editor: \(draft ? "PASS" : "FAIL")")
            print("Live nearby message: \(nearby ? "PASS" : "FAIL")")
            print("Capture budget: \(bounded ? "PASS" : "FAIL") (\(Int(result.1 * 1000)) ms)")
            window.orderOut(nil); previousApp?.activate(options: [])
            exit(draft && nearby && bounded ? 0 : 1)
        }
        app.run()
    }
}
