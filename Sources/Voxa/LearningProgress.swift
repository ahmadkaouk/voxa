import Combine
import Foundation

protocol LearningProgressStoring: Sendable {
    func load() async throws -> [LearningRecord]
    func save(_ records: [LearningRecord]) async throws
}

/// No excerpts, generated wording, full transcripts or audio are written here.
actor LearningProgressStore: LearningProgressStoring {
    private struct Document: Codable { let version: Int; let records: [LearningRecord] }
    private let url: URL
    static let limit = 200

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Voxa", isDirectory: true).appendingPathComponent("learning-progress.json")) {
        self.url = url
    }

    func load() throws -> [LearningRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1, document.records.count <= Self.limit,
              Set(document.records.map(\.id)).count == document.records.count,
              document.records.allSatisfy(\.isValid) else { throw FeedbackError.invalidResponse }
        return document.records
    }

    func save(_ records: [LearningRecord]) throws {
        guard records.count <= Self.limit, Set(records.map(\.id)).count == records.count,
              records.allSatisfy(\.isValid) else { throw FeedbackError.invalidResponse }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, records: records)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class LearningProgress: ObservableObject {
    @Published private(set) var records: [LearningRecord] = []
    @Published private(set) var ready = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?

    private enum Update { case record(LearningRecord), clear }
    private let store: any LearningProgressStoring
    private var pending: [Update] = []
    private var task: Task<Void, Never>?

    init(store: any LearningProgressStoring = LearningProgressStore()) {
        self.store = store
        retry()
    }

    var knownPatterns: Set<LearningFocus> {
        let queued = pending.compactMap { update -> LearningRecord? in
            if case .record(let record) = update { return record }; return nil
        }
        return Set((records + queued).flatMap { $0.mistakes + $0.suggestions })
    }

    var patterns: [PatternProgress] {
        LearningFocus.allCases.compactMap { focus in
            let mistakes = records.filter { $0.mistakes.contains(focus) }.count
            let suggestions = records.filter { $0.suggestions.contains(focus) }.count
            let successes = records.filter { $0.successes.contains(focus) }.count
            guard mistakes + suggestions + successes > 0 else { return nil }
            return PatternProgress(focus: focus, corrections: mistakes, suggestions: suggestions, successes: successes)
        }.sorted {
            if $0.corrections != $1.corrections { return $0.corrections > $1.corrections }
            return $0.focus.rawValue < $1.focus.rawValue
        }
    }

    var recentScores: [Int] { records.compactMap { $0.score?.rawValue } }
    var expressionProfile: ExpressionProfile { ExpressionProfile(records: records) }

    func record(_ record: LearningRecord) {
        guard record.isValid else { return }
        guard !records.contains(where: { $0.id == record.id }), !pending.contains(where: {
            if case .record(let item) = $0 { return item.id == record.id }; return false
        }) else { return }
        // Bounded even when storage is unavailable for a long time.
        if pending.count >= LearningProgressStore.limit { return }
        pending.append(.record(record))
        flush()
    }

    func clear() {
        guard ready, !isSaving else { return }
        pending = [.clear]
        error = nil
        flush()
    }

    func retry() {
        guard !isSaving else { return }
        error = nil
        if ready { flush(); return }
        isSaving = true
        task = Task { [weak self, store] in
            do {
                let records = try await store.load()
                guard let self else { return }
                self.records = records.sorted { $0.date > $1.date }; self.ready = true; self.isSaving = false
                self.task = nil; self.flush()
            } catch {
                guard let self else { return }
                self.isSaving = false; self.task = nil
                self.error = "Progress couldn’t be opened. Your existing file has been left untouched."
            }
        }
    }

    private func flush() {
        guard ready, !isSaving, error == nil, let next = pending.first else { return }
        let target: [LearningRecord]
        switch next {
        case .clear: target = []
        case .record(let record):
            if records.contains(where: { $0.id == record.id }) { pending.removeFirst(); flush(); return }
            target = Array(([record] + records.filter { $0.id != record.id })
                .sorted { $0.date > $1.date }.prefix(LearningProgressStore.limit))
        }
        isSaving = true
        task = Task { [weak self, store] in
            do {
                try await store.save(target)
                guard let self else { return }
                self.records = target; self.pending.removeFirst(); self.isSaving = false; self.task = nil
                self.flush()
            } catch {
                guard let self else { return }
                self.isSaving = false; self.task = nil
                self.error = "Progress couldn’t be saved. Retry to keep these observations."
            }
        }
    }

    func finishPendingWrites() async {
        while let task { await task.value }
    }
}
