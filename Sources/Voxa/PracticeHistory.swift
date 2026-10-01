import Combine
import Foundation

struct PracticeReview: Codable, Equatable, Sendable {
    let lessonID: UUID
    let attemptID: UUID
    let lastReviewed: Date
    let due: Date
    let streak: Int
    let attempts: Int

    var isValid: Bool { (0...5).contains(streak) && attempts > 0 && due >= lastReviewed }

    static func updated(_ old: Self?, lessonID: UUID, attemptID: UUID, success: Bool, now: Date) -> Self {
        if success, let old, now < old.due {
            return Self(lessonID: lessonID, attemptID: attemptID, lastReviewed: now,
                        due: old.due, streak: old.streak, attempts: old.attempts + 1)
        }
        let streak = success ? min(5, (old?.streak ?? 0) + 1) : 0
        let days = success ? [1, 3, 7, 14, 30][streak - 1] : 1
        return Self(lessonID: lessonID, attemptID: attemptID, lastReviewed: now,
                    due: now.addingTimeInterval(Double(days) * 86_400), streak: streak, attempts: (old?.attempts ?? 0) + 1)
    }
}

protocol PracticeHistoryStoring: Sendable {
    func load() async throws -> [PracticeReview]
    func save(_ reviews: [PracticeReview]) async throws
}

actor PracticeHistoryStore: PracticeHistoryStoring {
    private struct Document: Codable { let version: Int; let reviews: [PracticeReview] }
    private let url: URL
    static let limit = 500
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Voxa", isDirectory: true).appendingPathComponent("practice-history.json")) { self.url = url }

    func load() throws -> [PracticeReview] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1, Self.valid(document.reviews) else { throw FeedbackError.invalidResponse }
        return document.reviews
    }
    func save(_ reviews: [PracticeReview]) throws {
        guard Self.valid(reviews) else { throw FeedbackError.invalidResponse }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Document(version: 1, reviews: reviews))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func valid(_ reviews: [PracticeReview]) -> Bool {
        reviews.count <= limit && Set(reviews.map(\.lessonID)).count == reviews.count && reviews.allSatisfy(\.isValid)
    }
}

@MainActor
final class PracticeHistory: ObservableObject {
    @Published private(set) var reviews: [PracticeReview] = []
    @Published private(set) var ready = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    private enum Update { case attempt(UUID, UUID, Bool, Date), remove(Set<UUID>) }
    private let store: any PracticeHistoryStoring
    private var pending: [Update] = []
    private var task: Task<Void, Never>?

    init(store: any PracticeHistoryStoring = PracticeHistoryStore()) { self.store = store; retry() }

    func record(lessonID: UUID, attemptID: UUID, success: Bool, now: Date = Date()) {
        guard pending.count < PracticeHistoryStore.limit else { return }
        pending.append(.attempt(lessonID, attemptID, success, now)); flush()
    }
    func remove(_ ids: Set<UUID>) { pending.append(.remove(ids)); flush() }

    /// At most three due, distinct patterns. Recurring actual errors take priority over style.
    func queue(from lessons: [SavedCorrection], patterns: [PatternProgress], now: Date = Date()) -> [PracticeTarget] {
        guard ready, error == nil, !isSaving else { return [] }
        func key(_ lesson: SavedCorrection) -> String {
            lesson.feedback.focus?.rawValue ?? lesson.feedback.pattern ?? lesson.feedback.suggestion
        }
        // Several saved excerpts can teach the same pattern. Respect its most recent spacing.
        let postponed = Set(lessons.filter { lesson in
            reviews.contains { $0.lessonID == lesson.id && $0.due > now }
        }.map(key))
        let due = lessons.filter { lesson in
            lesson.feedback.kind != .transcriptionIssue && lesson.feedback.isValid
                && !postponed.contains(key(lesson))
                && (reviews.first { $0.lessonID == lesson.id }?.due ?? lesson.date) <= now
        }.sorted { lhs, rhs in
            let leftGrammar = lhs.feedback.kind != .phrasing, rightGrammar = rhs.feedback.kind != .phrasing
            if leftGrammar != rightGrammar { return leftGrammar }
            let leftCount = patterns.first { $0.focus == lhs.feedback.focus }?.corrections ?? 0
            let rightCount = patterns.first { $0.focus == rhs.feedback.focus }?.corrections ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let leftDue = reviews.first { $0.lessonID == lhs.id }?.due ?? lhs.date
            let rightDue = reviews.first { $0.lessonID == rhs.id }?.due ?? rhs.date
            return leftDue == rightDue ? lhs.id.uuidString < rhs.id.uuidString : leftDue < rightDue
        }
        var seen = Set<String>()
        return Array(due.filter {
            seen.insert(key($0)).inserted
        }.prefix(3)).map { PracticeTarget(lesson: $0, alternative: false) }
    }

    func retry() {
        guard !isSaving else { return }
        error = nil
        if ready { flush(); return }
        isSaving = true
        task = Task { [weak self, store] in
            do {
                let loaded = try await store.load()
                guard let self else { return }
                self.reviews = loaded; self.ready = true; self.isSaving = false; self.task = nil; self.flush()
            } catch {
                guard let self else { return }
                self.isSaving = false; self.task = nil
                self.error = "Review history couldn’t be opened. Your existing file is untouched."
            }
        }
    }

    private func flush() {
        guard ready, !isSaving, error == nil, let next = pending.first else { return }
        var updated = reviews
        switch next {
        case .attempt(let lessonID, let attemptID, let success, let date):
            let old = updated.first { $0.lessonID == lessonID }
            if old?.attemptID == attemptID { pending.removeFirst(); flush(); return }
            updated.removeAll { $0.lessonID == lessonID }
            updated.insert(.updated(old, lessonID: lessonID, attemptID: attemptID, success: success, now: date), at: 0)
            updated = Array(updated.prefix(PracticeHistoryStore.limit))
        case .remove(let ids): updated.removeAll { ids.contains($0.lessonID) }
        }
        let target = updated
        isSaving = true
        task = Task { [weak self, store] in
            do {
                try await store.save(target)
                guard let self else { return }
                self.reviews = target; self.pending.removeFirst(); self.isSaving = false; self.task = nil; self.flush()
            } catch {
                guard let self else { return }
                self.isSaving = false; self.task = nil
                self.error = "Review timing couldn’t be saved. Retry to keep this progress."
            }
        }
    }

    func finishPendingWrites() async { while let task { await task.value } }
}
