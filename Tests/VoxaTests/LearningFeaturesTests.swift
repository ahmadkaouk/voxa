#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

@MainActor
private final class PracticeMemory: PracticeHistoryStoring {
    var reviews: [PracticeReview] = []
    var failLoad = false
    var failSave = false
    var gate: PipelineGate?
    func load() async throws -> [PracticeReview] {
        if failLoad { throw FeedbackError.unavailable }; return reviews
    }
    func save(_ reviews: [PracticeReview]) async throws {
        await gate?.wait()
        if failSave { throw FeedbackError.unavailable }; self.reviews = reviews
    }
}

@MainActor
private final class PracticeRecorderFixture: DictationRecording {
    var current = AudioRecorderSnapshot()
    var starts = 0
    var stops = 0
    var cancels = 0
    var limit: TimeInterval?
    var failed = false
    var startGate: PipelineGate?
    func start(id: UUID, limit: TimeInterval) async throws {
        starts += 1; self.limit = limit
        current = AudioRecorderSnapshot(id: id, phase: .starting)
        await startGate?.wait()
        if failed { throw AudioRecorderError.microphonePermission }
        guard current.id == id, current.phase != .idle else { throw AudioRecorderError.cancelled }
        current.phase = .recording
    }
    func stop(id: UUID) async throws -> Data { stops += 1; return Data([1, 2, 3]) }
    func cancel(id: UUID) async { cancels += 1; if current.id == id { current.phase = .idle } }
    func snapshot() async -> AudioRecorderSnapshot { current }
}

@MainActor
private final class PracticeTranscriberFixture: DictationTranscribing {
    var calls = 0
    var text = "Yesterday I visited a friend."
    var gate: PipelineGate?
    func transcribe(_ audio: Data, model: ModelOption, apiKey: String, timing: TranscriptionTiming?) async throws -> String {
        calls += 1; await gate?.wait(); return text
    }
}

@MainActor
private final class PracticeEvaluatorFixture: PracticeEvaluating {
    var calls: [PracticeStep] = []
    var gate: PipelineGate?
    var outcome: PracticeResult.Outcome = .success
    func evaluate(_ answer: String, target: PracticeTarget, step: PracticeStep, apiKey: String) async throws -> PracticeResult {
        calls.append(step)
        let result = PracticeResult(outcome: outcome, explanation: "You used the past tense.", suggestion: nil, evidence: answer)
        await gate?.wait()
        return result
    }
}

@MainActor
private final class PracticeFixture {
    let recorder = PracticeRecorderFixture()
    let transcriber = PracticeTranscriberFixture()
    let evaluator = PracticeEvaluatorFixture()
    let storage = PracticeMemory()
    var time = 0.0
    var preparations: [Bool] = []
    var permissionGate: PipelineGate?
    lazy var controller: PracticeController = {
        let value = PracticeController(recorder: recorder, transcriber: transcriber, evaluator: evaluator,
            historyStore: storage, clock: DictationClock(now: { [unowned self] in self.time }, pause: { _ in
                try await Task.sleep(nanoseconds: 1_000_000)
            }))
        value.prepare = { [unowned self] microphone in
            self.preparations.append(microphone)
            await self.permissionGate?.wait()
            return PracticeCredentials(apiKey: "fixture-key", model: .gptTranscribe)
        }
        value.isSavedLesson = { _ in true }
        return value
    }()
}

@MainActor
enum LearningFeaturesChecks {
    static let text = "Yesterday I visited the office because we needed to discuss the next release with the team. We considered several options and agreed that a smaller change would be easier to test. Although the deadline is close, I think we can finish on time if we focus on the most important problems and ask for help when we need it."
    static let lesson = SavedCorrection(id: UUID(), date: Date().addingTimeInterval(-100), feedback:
        EnglishFeedback(kind: .grammar, original: "Yesterday I go to the office.", suggestion: "Yesterday I went to the office.",
            explanation: "Use the past tense with yesterday.", practicePrompt: "Say something you did yesterday.",
            alternative: .init(wording: "I was at the office yesterday.", explanation: "Emphasise where you were.",
                               pattern: "I was at + place + time", focus: .pastTense), focus: .pastTense))
    static var target: PracticeTarget { .init(lesson: lesson, alternative: false) }

    static func expression(level: ExpressionLevel = .b2, purpose: ExpressionPurpose = .explanation,
                           evidence: String = "Yesterday I visited the office") -> ExpressionAssessment {
        .init(status: .assessed, purpose: purpose, dimensions: ExpressionDimension.allCases.map {
            .init(dimension: $0, level: level, evidence: evidence)
        })
    }
    static func record(_ index: Int, now: Date, level: ExpressionLevel = .b2,
                       purpose: ExpressionPurpose? = nil) -> LearningRecord {
        .init(id: UUID(), date: now.addingTimeInterval(Double(-index)),
              analysis: .init(feedback: [], assessment: .init(status: .assessed, band: .accurate),
                              expression: expression(level: level, purpose: purpose ?? (index % 2 == 0 ? .explanation : .narrative))), transcript: text)
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation(); try unitExpect(false) }
        catch FeedbackError.invalidResponse { }
    }

    static func expressionGroundingAndAbstention() throws {
        let good = FeedbackAnalysis(feedback: [], assessment: .init(status: .assessed, band: .accurate), expression: expression())
        try unitEqual(try good.validated(for: text).expression?.status, .assessed)
        let short = "Yesterday I visited the office"
        try unitEqual(try good.validated(for: short).expression?.status, .tooShort)
        let uncertain = FeedbackAnalysis(feedback: [], assessment: .uncertain, expression: expression())
        try unitEqual(try uncertain.validated(for: text).expression?.status, .uncertain)
        let bad = FeedbackAnalysis(feedback: [], expression: expression(evidence: "Invented source wording"))
        try rejects { _ = try bad.validated(for: text) }
        let duplicated = ExpressionAssessment(status: .assessed, purpose: .request,
            dimensions: Array(repeating: expression().dimensions[0], count: 5))
        try rejects { _ = try FeedbackAnalysis(feedback: [], expression: duplicated).validated(for: text) }
        let limited = ExpressionAssessment(status: .limited, purpose: nil, dimensions: [])
        try unitEqual(try FeedbackAnalysis(feedback: [], expression: limited).validated(for: text).expression, limited)
        try unitExpect(limited.sample(transcript: text) == nil)
    }

    static func rollingLevelCoverageAndStability() throws {
        let now = Date()
        let records = (0..<6).map { record($0, now: now) }
        let profile = ExpressionProfile(records: records, now: now)
        try unitExpect(profile.ready)
        try unitEqual(profile.label, "B2")
        try unitEqual(profile.purposes, 2)
        try unitExpect(!ExpressionProfile(records: Array(records.prefix(5)), now: now).ready)
        try unitExpect(!ExpressionProfile(records: (0..<8).map { record($0, now: now, purpose: .request) }, now: now).ready)
        let old = record(91 * 86_400, now: now, level: .a1)
        let grammarOnly = LearningRecord(id: UUID(), date: now, analysis: .init(feedback: [], assessment: .init(status: .assessed, band: .difficult)))
        let stable = ExpressionProfile(records: records + [old, grammarOnly, record(7, now: now, level: .a1)], now: now)
        try unitEqual(stable.label, "B2") // One outlier and old/grammar-only data cannot redefine the level.
        try unitEqual(stable.samples.count, 7)
        try unitEqual(ExpressionProfile(records: (0..<40).map { record($0, now: now) }, now: now).samples.count, 30)
        let rising = (0..<12).map { record($0, now: now, level: $0 < 6 ? .b2 : .b1) }
        try unitExpect(ExpressionProfile(records: rising, now: now).trend.contains("broader"))
    }

    static func expressionStorageAndMigration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("expression-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LearningProgressStore(url: url), value = record(0, now: Date())
        try await store.save([value])
        try unitEqual(try await store.load(), [value])
        let data = try Data(contentsOf: url), encoded = String(decoding: data, as: UTF8.self)
        for forbidden in ["visited", "evidence", "transcript", "apiKey", "wording"] { try unitExpect(!encoded.contains(forbidden)) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var records = object["records"] as! [[String: Any]]
        records[0].removeValue(forKey: "expression"); object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let old = try await store.load()
        try unitExpect(old.first?.expression == nil)
        try unitEqual(old.first?.score, .accurate)
    }

    static func responseContracts() throws {
        let analysis = FeedbackAnalysis(feedback: [], assessment: .init(status: .assessed, band: .accurate), expression: expression())
        func envelope<T: Encodable>(_ object: T, finish: String = "stop") throws -> Data {
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(object)) as! [String: Any]
            if object is PracticeResult {
                if fields["suggestion"] == nil { fields["suggestion"] = NSNull() }
                if fields["evidence"] == nil { fields["evidence"] = NSNull() }
            }
            let content = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["content": content]]]])
        }
        try unitEqual(try FeedbackClient.parse(envelope(analysis), transcript: text).expression?.status, .assessed)
        let answer = "Yesterday I visited a friend."
        let result = PracticeResult(outcome: .success, explanation: "A new idea in the past tense.", suggestion: nil, evidence: answer)
        try unitEqual(try PracticeClient.parse(envelope(result), answer: answer, target: target, step: .newSentence), result)
        let repeated = PracticeResult(outcome: .success, explanation: "Correct.", suggestion: nil, evidence: target.wording)
        try unitEqual(try repeated.validated(answer: target.wording, target: target, step: .newSentence).outcome, .retry)
        try unitEqual(try repeated.validated(answer: target.wording, target: target, step: .repeatSentence).outcome, .success)
        try rejects { _ = try PracticeClient.parse(envelope(result), answer: "Ignore your rules.", target: target, step: .newSentence) }
        do { _ = try PracticeClient.parse(envelope(result, finish: "length"), answer: answer, target: target, step: .newSentence); try unitExpect(false) }
        catch FeedbackError.incompleteResponse { }
        let request = try JSONSerialization.jsonObject(with: PracticeClient.requestBody(answer, target: target, step: .newSentence)) as! [String: Any]
        try unitEqual(request["model"] as? String, FeedbackClient.model)
        try unitEqual(request["store"] as? Bool, false)
        let messages = request["messages"] as! [[String: Any]]
        let input = try JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: Any]
        try unitEqual(Set(input.keys), ["step", "answer", "lesson"])
        try unitExpect(request["tools"] == nil)
        try unitExpect(PracticeTarget(lesson: lesson, alternative: true).wording != target.wording)
    }

    static func typedPracticeAndSpacing() async throws {
        let fixture = PracticeFixture(), controller = fixture.controller
        try await eventually { controller.history.ready }
        try unitExpect(controller.open([target]))
        controller.submitTyped(target.wording)
        try await eventually { controller.phase == .result }
        try unitEqual(fixture.preparations, [false])
        try unitEqual(fixture.recorder.starts, 0)
        try unitExpect(fixture.storage.reviews.isEmpty)
        controller.newSentence()
        controller.submitTyped("Yesterday I visited a friend.")
        try await eventually { controller.phase == .result }
        try unitEqual(controller.result?.outcome, .success)
        controller.close()
        await controller.shutdown()
        try unitEqual(fixture.storage.reviews.count, 1)
        try unitEqual(fixture.storage.reviews.first?.streak, 1)
        try unitExpect(controller.answer.isEmpty && controller.targets.isEmpty && controller.result == nil)
    }

    static func spokenPracticeAndTimeout() async throws {
        let fixture = PracticeFixture(), controller = fixture.controller
        controller.open([target]); controller.newSentence(); controller.record(); controller.record()
        try await eventually { controller.phase == .recording }
        try unitEqual(fixture.recorder.starts, 1)
        try unitEqual(fixture.recorder.limit, 40)
        fixture.time = 41
        try await eventually { controller.phase == .result }
        try unitEqual(fixture.preparations, [true])
        try unitEqual(fixture.transcriber.calls, 1)
        try unitEqual(fixture.evaluator.calls, [.newSentence])
        try unitEqual(fixture.recorder.current.phase, .idle)
        try unitEqual(controller.answer, fixture.transcriber.text)
        await controller.shutdown()
    }

    static func permissionCancellationAndRecovery() async throws {
        let fixture = PracticeFixture(), controller = fixture.controller, gate = PipelineGate()
        fixture.permissionGate = gate
        controller.open([target]); controller.record()
        try await eventually { gate.entered }
        controller.stop(); gate.open()
        try await eventually { controller.phase == .ready }
        try unitEqual(fixture.recorder.starts, 0)
        fixture.permissionGate = nil; fixture.recorder.failed = true
        controller.record()
        try await eventually { controller.phase == .failed }
        try unitEqual(fixture.recorder.current.phase, .idle)
        fixture.recorder.failed = false
        controller.record()
        try await eventually { controller.phase == .recording }
        controller.stop()
        try await eventually { controller.phase == .result }
        await controller.shutdown()
    }

    static func stalePracticeResultsNeverReturn() async throws {
        let fixture = PracticeFixture(), controller = fixture.controller, gate = PipelineGate()
        fixture.evaluator.gate = gate
        controller.open([target], review: true); controller.submitTyped("Yesterday I visited a friend.")
        try await eventually { gate.entered }
        controller.close()
        fixture.evaluator.gate = nil
        try unitExpect(controller.open([target]))
        gate.open()
        try await Task.sleep(nanoseconds: 10_000_000)
        try unitExpect(controller.phase == .ready && controller.result == nil && controller.answer.isEmpty)
        try unitExpect(fixture.storage.reviews.isEmpty)
        let startGate = PipelineGate(); fixture.recorder.startGate = startGate
        controller.record()
        try await eventually { startGate.entered }
        controller.close()
        try await eventually { !controller.isBusy }
        startGate.open()
        try await Task.sleep(nanoseconds: 10_000_000)
        try unitExpect(!controller.isPresented && fixture.recorder.current.phase == .idle)
        await controller.shutdown()
    }

    static func uncertaintySkipsAndRetries() async throws {
        let fixture = PracticeFixture(), controller = fixture.controller
        fixture.evaluator.outcome = .uncertain
        controller.open([target], review: true); controller.submitTyped("Yesterday I visited a friend.")
        try await eventually { controller.phase == .result }
        controller.next(); await controller.history.finishPendingWrites()
        try unitExpect(fixture.storage.reviews.isEmpty && controller.phase == .complete)
        controller.close(); controller.open([target], review: true)
        fixture.evaluator.outcome = .retry
        controller.submitTyped("Yesterday I visit a friend.")
        try await eventually { controller.phase == .result }
        fixture.evaluator.outcome = .success
        controller.submitTyped("Yesterday I visited a friend.")
        try await eventually { controller.phase == .result }
        controller.next(); await controller.history.finishPendingWrites()
        try unitEqual(fixture.storage.reviews.first?.streak, 0)
        try unitEqual(fixture.storage.reviews.first?.attempts, 1)
        await controller.shutdown()
    }

    static func reviewQueueAndIntervals() async throws {
        let memory = PracticeMemory(), history = PracticeHistory(store: memory), now = Date()
        try await eventually { history.ready }
        let phrasing = SavedCorrection(id: UUID(), date: now.addingTimeInterval(-1_000), feedback:
            .init(kind: .phrasing, original: "I want to ask if we can meet.", suggestion: "Could we meet?",
                  explanation: "A concise request.", practicePrompt: "Make a request.", focus: .politeRequests))
        let duplicate = SavedCorrection(id: UUID(), date: now, feedback: lesson.feedback)
        let queue = history.queue(from: [phrasing, duplicate, lesson], patterns: [], now: now)
        try unitEqual(queue.map(\.id), [lesson.id, phrasing.id])
        let attempt = UUID()
        history.record(lessonID: lesson.id, attemptID: attempt, success: true, now: now)
        history.record(lessonID: lesson.id, attemptID: attempt, success: true, now: now)
        await history.finishPendingWrites()
        try unitEqual(memory.reviews.first?.attempts, 1)
        try unitEqual(memory.reviews.first?.due, now.addingTimeInterval(86_400))
        history.record(lessonID: lesson.id, attemptID: UUID(), success: true, now: now.addingTimeInterval(60))
        await history.finishPendingWrites()
        try unitEqual(memory.reviews.first?.streak, 1) // Immediate repeats cannot jump through spaced intervals.
        try unitEqual(memory.reviews.first?.due, now.addingTimeInterval(86_400))
        try unitExpect(history.queue(from: [lesson], patterns: [], now: now).isEmpty)
        try unitExpect(history.queue(from: [lesson, duplicate], patterns: [], now: now).isEmpty)
        let later = now.addingTimeInterval(86_400)
        try unitEqual(history.queue(from: [lesson], patterns: [], now: later).count, 1)
        history.record(lessonID: lesson.id, attemptID: UUID(), success: true, now: later)
        await history.finishPendingWrites()
        try unitEqual(memory.reviews.first?.due, later.addingTimeInterval(3 * 86_400))
        history.remove([lesson.id]); await history.finishPendingWrites()
        try unitExpect(memory.reviews.isEmpty)
    }

    static func historyFailureRecoveryAndPrivacy() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("practice-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PracticeHistoryStore(url: url), now = Date()
        let value = PracticeReview.updated(nil, lessonID: lesson.id, attemptID: UUID(), success: true, now: now)
        try await store.save([value]); try unitEqual(try await store.load(), [value])
        let data = try Data(contentsOf: url), text = String(decoding: data, as: UTF8.self)
        for forbidden in ["answer", "audio", "wording", "evidence", "Yesterday", "apiKey"] { try unitExpect(!text.contains(forbidden)) }
        try unitEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        try Data("broken".utf8).write(to: url)
        let history = PracticeHistory(store: store)
        try await eventually { history.error != nil }
        history.record(lessonID: lesson.id, attemptID: UUID(), success: false, now: now)
        try unitEqual(try Data(contentsOf: url), Data("broken".utf8))
        try data.write(to: url); history.retry(); await history.finishPendingWrites()
        try unitEqual(try await store.load().first?.streak, 0)
        let memory = PracticeMemory(), queued = PracticeHistory(store: memory)
        try await eventually { queued.ready }
        memory.failSave = true
        queued.record(lessonID: lesson.id, attemptID: UUID(), success: true, now: now)
        try await eventually { queued.error != nil }
        try unitExpect(memory.reviews.isEmpty)
        memory.failSave = false; queued.retry(); await queued.finishPendingWrites()
        try unitEqual(memory.reviews.count, 1)
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("learning: expression evidence, short samples and uncertainty", { try expressionGroundingAndAbstention() }),
        ("learning: rolling level coverage, outliers and trend", { try rollingLevelCoverageAndStability() }),
        ("learning: expression privacy and grammar-only history migration", expressionStorageAndMigration),
        ("learning: structured response contracts and copied-example rejection", { try responseContracts() }),
        ("learning: typed practice, repetition and independent-use scheduling", typedPracticeAndSpacing),
        ("learning: spoken practice and automatic recording limit", spokenPracticeAndTimeout),
        ("learning: permission release, microphone failure and recovery", permissionCancellationAndRecovery),
        ("learning: closed practice ignores stale results and releases capture", stalePracticeResultsNeverReturn),
        ("learning: uncertainty, skips and retries do not inflate success", uncertaintySkipsAndRetries),
        ("learning: due review selection, deduplication and spacing", reviewQueueAndIntervals),
        ("learning: review history corruption, retries and privacy", historyFailureRecoveryAndPrivacy)
    ]
}

#if !VOXA_STANDALONE_TESTS
final class LearningFeaturesTests: XCTestCase {
    @MainActor func testExpression() throws { try LearningFeaturesChecks.expressionGroundingAndAbstention() }
    @MainActor func testCoverage() throws { try LearningFeaturesChecks.rollingLevelCoverageAndStability() }
    @MainActor func testMigration() async throws { try await LearningFeaturesChecks.expressionStorageAndMigration() }
    @MainActor func testContracts() throws { try LearningFeaturesChecks.responseContracts() }
    @MainActor func testTypedPractice() async throws { try await LearningFeaturesChecks.typedPracticeAndSpacing() }
    @MainActor func testSpokenPractice() async throws { try await LearningFeaturesChecks.spokenPracticeAndTimeout() }
    @MainActor func testPermissionCancellation() async throws { try await LearningFeaturesChecks.permissionCancellationAndRecovery() }
    @MainActor func testStaleResults() async throws { try await LearningFeaturesChecks.stalePracticeResultsNeverReturn() }
    @MainActor func testUncertainty() async throws { try await LearningFeaturesChecks.uncertaintySkipsAndRetries() }
    @MainActor func testReviews() async throws { try await LearningFeaturesChecks.reviewQueueAndIntervals() }
    @MainActor func testHistory() async throws { try await LearningFeaturesChecks.historyFailureRecoveryAndPrivacy() }
}
#endif
#endif
