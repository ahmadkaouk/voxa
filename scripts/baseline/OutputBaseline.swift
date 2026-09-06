import AppKit
import Foundation

@main
private enum OutputBaseline {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        DispatchQueue.global().async {
            do {
                let board = onPasteboardThread { NSPasteboard.withUniqueName() }
                defer { onPasteboardThread { board.releaseGlobally() } }
                var timings: [Double] = []
                for i in 0..<33 {
                    onPasteboardThread {
                        board.clearContents()
                        board.setString("baseline original", forType: .string)
                    }
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = ClipboardAutopaster(pasteboard: board).paste("fixture transcript") { _ in
                        // Simulate a consumer reading the isolated pasteboard; no key events.
                        onPasteboardThread { board.string(forType: .string) } == "fixture transcript"
                    }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    guard result == .restored,
                          onPasteboardThread({ board.string(forType: .string) }) == "baseline original"
                    else { throw CocoaError(.validationMissingMandatoryProperty) }
                    if i >= 3 { timings.append(elapsed) }
                }
                let report: [String: Any] = [
                    "schema_version": 1, "kind": "swift_output_fixture", "build": "swiftc -O",
                    "clock": "DispatchTime.uptimeNanoseconds", "sample_count": timings.count,
                    "warmup_samples_excluded": 3, "settling_delay_ms": 500,
                    "metrics_ms": ["pasteboard_read_and_restore": timings],
                    "limitations": ["Isolated named pasteboard; no system clipboard changes",
                                    "Simulated immediate consumer; no foreground app or paste shortcut",
                                    "Includes the production 500 ms settling delay"]
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("output-metrics.json"))
                exit(0)
            } catch {
                fputs("Output baseline failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
