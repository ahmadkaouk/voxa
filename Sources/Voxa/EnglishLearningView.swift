import AppKit
import SwiftUI

private typealias LearningViewState<Value> = SwiftUI.State<Value>

enum LearningSection: String, CaseIterable, Identifiable {
    case allLessons, corrections, phrasing, practice, progress
    var id: Self { self }
    var title: String {
        switch self {
        case .allLessons: return "All Lessons"
        case .corrections: return "Corrections"
        case .phrasing: return "Natural Phrasing"
        case .practice: return "Practice"
        case .progress: return "Progress"
        }
    }
    var symbol: String {
        switch self {
        case .allLessons: return "tray"
        case .corrections: return "text.badge.checkmark"
        case .phrasing: return "text.bubble"
        case .practice: return "arrow.triangle.2.circlepath"
        case .progress: return "chart.bar"
        }
    }
    var isLibrary: Bool { self == .allLessons || self == .corrections || self == .phrasing }

    func lessons(in saved: [SavedCorrection], matching query: String = "") -> [SavedCorrection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.filter { item in
            let feedback = item.feedback
            let matchesSection = self == .allLessons
                || (self == .corrections && (feedback.kind == .grammar || feedback.kind == .construction))
                || (self == .phrasing && (feedback.kind == .phrasing || feedback.alternative != nil))
            let searchable = [feedback.original, feedback.suggestion, feedback.explanation,
                              feedback.pattern, feedback.focus?.label, feedback.alternative?.wording,
                              feedback.alternative?.explanation, feedback.alternative?.pattern,
                              feedback.alternative?.focus?.label].compactMap { $0 }
            return matchesSection && (query.isEmpty || searchable.contains { $0.localizedStandardContains(query) })
        }
    }
}

@MainActor
struct VoxaLearningView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        SavedCorrectionsView(controller: controller.feedback, history: controller.practice.history,
                             canPractice: controller.canOpenPractice, onShortReview: controller.startShortReview)
    }
}

struct SavedCorrectionsView: View {
    @ObservedObject var controller: FeedbackController
    @ObservedObject var history: PracticeHistory
    var canPractice: Bool
    var onShortReview: (() -> Void)?
    @LearningViewState private var section: LearningSection?
    @LearningViewState private var search: String
    @LearningViewState private var selection: UUID?
    @LearningViewState private var confirmDeleteAll = false

    init(controller: FeedbackController, history: PracticeHistory, canPractice: Bool = true,
         onShortReview: (() -> Void)? = nil, initialSection: LearningSection = .allLessons,
         initialSearch: String = "") {
        self.controller = controller; self.history = history
        self.canPractice = canPractice; self.onShortReview = onShortReview
        _section = .init(initialValue: initialSection)
        _search = .init(initialValue: initialSearch)
        _selection = .init(initialValue: initialSection.lessons(in: controller.saved, matching: initialSearch).first?.id)
    }

    private var currentSection: LearningSection { section ?? .allLessons }
    private var lessons: [SavedCorrection] { currentSection.lessons(in: controller.saved, matching: search) }
    private var reviewReady: Bool { canPractice && history.ready && !history.isSaving && history.error == nil }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") {
                    ForEach([LearningSection.allLessons, .corrections, .phrasing]) { item in
                        VoxaSidebarLabel(title: item.title, symbol: item.symbol)
                            .badge(item.lessons(in: controller.saved).count)
                            .tag(item)
                    }
                }
                Section("Learning") {
                    ForEach([LearningSection.practice, .progress]) { item in
                        VoxaSidebarLabel(title: item.title, symbol: item.symbol).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
            .safeAreaInset(edge: .bottom) {
                Label("On this Mac", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .navigationTitle("English Learning")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            // Constrain nested split and scrolling views to the current native column.
            GeometryReader { geometry in
                Group {
                    if currentSection.isLibrary { library }
                    else if currentSection == .practice { practice }
                    else { LearningProgressView(progress: controller.progress) }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .navigationTitle(currentSection.title)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $search, placement: .sidebar, prompt: "Search lessons")
        .frame(minWidth: 940, idealWidth: 1060, minHeight: 560, idealHeight: 680, alignment: .topLeading)
        .toolbar {
            if let onShortReview, currentSection.isLibrary {
                Button(action: onShortReview) { Label("Review", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!reviewReady || controller.saved.isEmpty)
                    .help("Start a one-minute review")
            }
            if currentSection.isLibrary {
                Menu {
                    Button("Delete All Saved Lessons…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(controller.saved.isEmpty || controller.isSaving || !controller.storageReady)
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .help("Manage saved lessons")
            }
        }
        .onChange(of: lessons.map(\.id)) { ids in
            if !ids.contains(where: { $0 == selection }) { selection = ids.first }
        }
        .onChange(of: search) { query in
            if !query.isEmpty && !currentSection.isLibrary { section = .allLessons }
        }
        .alert("Delete all saved lessons?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { controller.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes your saved corrections from this Mac.") }
    }

    private var library: some View {
        VStack(spacing: 0) {
            if let error = controller.storageError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    Spacer()
                    Button("Retry") { controller.reloadSaved() }.disabled(controller.isSaving)
                }.padding(16)
                Divider()
            }
            HSplitView {
                VStack(spacing: 0) {
                    List(lessons, selection: $selection) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.feedback.focus?.label ?? item.feedback.kind.label)
                                .font(.headline).lineLimit(1)
                            Text(item.feedback.suggestion).font(.callout).lineLimit(2)
                                .foregroundStyle(.secondary)
                            Text(item.date, format: .dateTime.month(.abbreviated).day())
                                .font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8).tag(item.id)
                    }.listStyle(.inset)
                    Divider()
                    Text("\(lessons.count) \(lessons.count == 1 ? "lesson" : "lessons")")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                if let item = lessons.first(where: { $0.id == selection }) {
                    CorrectionDetailView(item: item, isSaving: controller.isSaving,
                        canPractice: canPractice, onPractice: { controller.practise(item, alternative: $0) },
                        onDelete: { controller.delete(item.id) })
                        .id(item.id)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LearningEmptyState(symbol: search.isEmpty ? "bookmark" : "magnifyingglass",
                        title: controller.isSaving && !controller.storageReady ? "Opening your lessons…" :
                            !search.isEmpty ? "No matching lessons" : "Your lessons start here",
                        detail: !search.isEmpty ? "Try another word or clear the search." :
                            currentSection == .allLessons ? "Choose Save after dictation to keep a useful pattern.\nYou can revisit it and practise here." :
                            "Lessons in this category will appear here when you save them.")
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var practice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Practice").font(.title2.weight(.semibold))
                    Text("Make the patterns you’ve saved part of your everyday English.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = history.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Button("Retry") { history.retry() }.disabled(history.isSaving)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("One-minute review", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Text("Try up to three patterns in a new sentence. Speak or type your answer.")
                            .foregroundStyle(.secondary)
                        if let onShortReview {
                            Button("Start Review", action: onShortReview).buttonStyle(.borderedProminent)
                                .disabled(!reviewReady || controller.saved.isEmpty)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    let due = history.queue(from: controller.saved, patterns: controller.progress.patterns, now: timeline.date)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Next review").font(.headline)
                        if history.error != nil {
                            Text("Retry review timing to see what’s due.").foregroundStyle(.secondary)
                        } else if !history.ready || history.isSaving {
                            Text("Loading review timing…").foregroundStyle(.secondary)
                        } else if due.isEmpty {
                            Text(controller.saved.isEmpty ? "Save a lesson after dictation to start practising." :
                                "You’re caught up. You can still practise any lesson from your library.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(due) { target in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(target.focus?.label ?? target.lesson.feedback.kind.label).font(.headline)
                                    Text(target.wording).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Divider()
                            }
                        }
                    }
                }
                Text("Reviewed patterns return over time. Practice is tracked separately from the level estimated from your dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 640, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
    }
}

private struct LearningEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28)
    }
}

private struct CorrectionDetailView: View {
    let item: SavedCorrection
    let isSaving: Bool
    let canPractice: Bool
    let onPractice: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.feedback.focus?.label ?? item.feedback.kind.label).font(.title2.weight(.semibold))
                        Text(item.date, format: .dateTime.month(.wide).day().year())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(isSaving).help("Delete lesson")
                        .accessibilityLabel("Delete this lesson")
                }
                FeedbackLessonView(feedback: item.feedback, onPractice: onPractice).disabled(!canPractice)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    sentence("Original", item.feedback.original)
                    sentence(item.feedback.kind == .phrasing ? "Alternative" : "Corrected", item.feedback.suggestion)
                }.textSelection(.enabled)
            }.padding(28).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func sentence(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}
