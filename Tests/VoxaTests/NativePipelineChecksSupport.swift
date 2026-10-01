#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation

@MainActor
func eventually(_ condition: () -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        try unitExpect(ProcessInfo.processInfo.systemUptime < deadline, file: file, line: line)
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Deliberately ignores task cancellation to test late, uncooperative completions.
@MainActor
final class PipelineGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var opened = false
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

#if VOXA_PIPELINE_TEST_RUNNER
@main
private enum NativePipelineChecksRunner {
    static func main() {
        // A real main run loop is needed for the isolated pasteboard's lazy data provider.
        Task { @MainActor in
            do {
                let checks = DictationSessionChecks.all + TranscriptionClientChecks.all + AsyncTranscriptOutputChecks.all + NativeSetupChecks.all + FeedbackChecks.all + LearningFeaturesChecks.all
                for (name, check) in checks { try await check(); print("PASS: \(name)") }
                print("All \(checks.count) native pipeline checks passed (fixtures; no microphone or external API)")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }
}
#endif
#endif
