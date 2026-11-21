import AppKit
import SwiftUI

private typealias LearningViewState<Value> = SwiftUI.State<Value>

enum LearningSection: String, CaseIterable, Identifiable {
    case mistakes, saved, practice
    var id: Self { self }
    var title: String {
        switch self {
        case .mistakes: return "Repeat mistakes"
        case .saved: return "Saved fixes"
        case .practice: return "Practice"
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

/// The English Learning window: the mistakes you repeat, the fixes you saved, and practice,
/// drawn with the same You said → Better rows as the feedback review.
struct SavedCorrectionsView: View {
    @ObservedObject var controller: FeedbackController
    @ObservedObject var history: PracticeHistory
    var canPractice: Bool
    var onShortReview: (() -> Void)?
    @LearningViewState private var section: LearningSection
    @LearningViewState private var search: String
    @LearningViewState private var expanded: String?
    @LearningViewState private var confirmDeleteAll = false
    @LearningViewState private var confirmClear = false

    init(controller: FeedbackController, history: PracticeHistory, canPractice: Bool = true,
         onShortReview: (() -> Void)? = nil, initialSection: LearningSection = .mistakes,
         initialSearch: String = "") {
        self.controller = controller; self.history = history
        self.canPractice = canPractice; self.onShortReview = onShortReview
        _section = .init(initialValue: initialSearch.isEmpty ? initialSection : .saved)
        _search = .init(initialValue: initialSearch)
    }

    private var mistakes: [RepeatedMistake] {
        LearningLibrary.repeatedMistakes(patterns: controller.progress.patterns, saved: controller.saved)
    }
    private var fixes: [SavedCorrection] { LearningLibrary.fixes(in: controller.saved, matching: search) }
    private var reviewReady: Bool { canPractice && history.ready && !history.isSaving && history.error == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch section {
                case .mistakes: mistakesPage
                case .saved: savedPage
                case .practice: practicePage
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            .alert("Clear your mistake history?", isPresented: $confirmClear) {
                Button("Clear history", role: .destructive) { controller.progress.clear() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the mistake counts from this Mac. Your saved fixes and review timing stay available.") }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("English Learning")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(LearningSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Delete All Saved Fixes…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(controller.saved.isEmpty || controller.isSaving || !controller.storageReady)
                    Button("Clear Mistake History…", role: .destructive) { confirmClear = true }
                        .disabled(!controller.progress.ready || controller.progress.isSaving || controller.progress.records.isEmpty)
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .help("Manage saved fixes and history")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search saved fixes")
        .onChange(of: search) { query in if !query.isEmpty { section = .saved } }
        .onChange(of: section) { _ in expanded = nil }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 520, idealHeight: 700, alignment: .topLeading)
        .alert("Delete all saved fixes?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { controller.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes your saved fixes from this Mac.") }
    }

    // MARK: Repeat mistakes

    private var mistakesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("What you keep getting wrong", detail: "From your feedback reviews")
            if let error = controller.progress.error {
                banner(error, busy: controller.progress.isSaving) { controller.progress.retry() }
            }
            if mistakes.isEmpty {
                emptyState(controller.progress.ready ? "Nothing yet" : "Opening your history…",
                           detail: "Mistakes from your feedback reviews appear here, with examples from the fixes you save.")
            } else {
                columnLabels("How often")
                ForEach(Array(mistakes.enumerated()), id: \.element.id) { index, mistake in
                    if index > 0 { rowDivider }
                    mistakeRow(mistake)
                }
            }
            footnote("Counts come from your feedback reviews; examples come from the fixes you save. Both stay on this Mac.")
        }
    }

    private func mistakeRow(_ mistake: RepeatedMistake) -> some View {
        let key = "mistake-" + mistake.id.rawValue
        let open = expanded == key
        let latest = mistake.examples.first
        return VStack(alignment: .leading, spacing: 12) {
            Button { expanded = open ? nil : key } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let latest { Text(pair(latest).saidText) }
                        Text(mistake.pattern.focus.label)
                            .font(latest == nil ? .system(size: 15, weight: .medium) : .system(size: 12))
                            .foregroundColor(latest == nil ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    arrow
                    Group {
                        if let latest { Text(pair(latest).betterText(size: 15)) }
                        else { Text("No saved example yet").foregroundColor(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(mistake.count) \(mistake.count == 1 ? "review" : "reviews")")
                        .font(.system(size: 13))
                        .foregroundColor(mistake.count >= 3 ? Color(nsColor: FeedbackInk.again) : .secondary)
                        .frame(width: 96, alignment: .trailing)
                }
                .font(.system(size: 15)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the details" : "Shows the reason and your examples")
            if open, let latest {
                FeedbackFixDetail(feedback: latest.feedback)
                if mistake.examples.count > 1 { examples(Array(mistake.examples.prefix(3))) }
                practiceButton(latest)
            }
        }
        .modifier(LearningRowSurface(open: open))
    }

    private func examples(_ items: [SavedCorrection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.date, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Text(pair(item).saidText + AttributedString("  →  ") + pair(item).betterText(size: 13))
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5) } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Saved fixes

    private var savedPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Saved fixes", detail: "\(controller.saved.count) \(controller.saved.count == 1 ? "fix" : "fixes")")
            if let error = controller.storageError {
                banner(error, busy: controller.isSaving) { controller.reloadSaved() }
            }
            if fixes.isEmpty {
                emptyState(controller.isSaving && !controller.storageReady ? "Opening your fixes…"
                               : search.isEmpty ? "Nothing saved yet" : "No matching fixes",
                           detail: search.isEmpty ? "Choose Got it after a review to keep its fixes here."
                               : "Try another word or clear the search.")
            } else {
                columnLabels("Saved")
                ForEach(Array(fixes.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rowDivider }
                    savedRow(item)
                }
            }
        }
    }

    private func savedRow(_ item: SavedCorrection) -> some View {
        let key = "saved-" + item.id.uuidString
        let open = expanded == key
        return VStack(alignment: .leading, spacing: 12) {
            Button { expanded = open ? nil : key } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pair(item).saidText)
                        if let focus = item.feedback.focus {
                            Text(focus.label).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    arrow
                    Text(pair(item).betterText(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.date, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)
                }
                .font(.system(size: 15)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("You said: \(item.feedback.original). Better: \(item.feedback.suggestion)")
            .accessibilityHint(open ? "Hides the details" : "Shows the reason and practice")
            if open {
                FeedbackFixDetail(feedback: item.feedback)
                HStack(spacing: 8) {
                    practiceButton(item)
                    Spacer()
                    Button(role: .destructive) { controller.delete(item.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.borderless).disabled(controller.isSaving).help("Delete this saved fix")
                }
            }
        }
        .modifier(LearningRowSurface(open: open))
    }

    // MARK: Practice

    private var practicePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Practice", detail: "Use what you saved in a new sentence")
            if let error = history.error {
                banner(error, busy: history.isSaving) { history.retry() }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("One-minute review").font(.system(size: 15, weight: .semibold))
                Text("Try up to three saved fixes in a new sentence. Speak or type your answer.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let onShortReview {
                    Button("Start Review", action: onShortReview).buttonStyle(.borderedProminent)
                        .disabled(!reviewReady || controller.saved.isEmpty).padding(.top, 4)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 22)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let due = history.queue(from: controller.saved, patterns: controller.progress.patterns, now: timeline.date)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Due next").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 4)
                    if history.error != nil {
                        note("Retry review timing to see what’s due.")
                    } else if !history.ready || history.isSaving {
                        note("Loading review timing…")
                    } else if due.isEmpty {
                        note(controller.saved.isEmpty ? "Save fixes with Got it after a review to start practising."
                             : "You’re caught up. You can still practise any saved fix.")
                    } else {
                        ForEach(Array(due.enumerated()), id: \.element.id) { index, target in
                            if index > 0 { rowDivider }
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(target.focus?.label ?? "Saved fix").font(.system(size: 13)).foregroundStyle(.secondary)
                                    .frame(width: 150, alignment: .leading)
                                Text(target.wording).font(.system(size: 15)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                        }
                    }
                }
            }
            footnote("Practised fixes come back after 1, 3, 7, 14 and 30 days. Practice is kept apart from your mistake history.")
        }
    }

    // MARK: Shared pieces

    private func pair(_ item: SavedCorrection) -> FeedbackPairText {
        FeedbackPairText(said: item.feedback.original, better: item.feedback.suggestion)
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.bottom, 18)
    }

    private func columnLabels(_ last: String) -> some View {
        HStack(spacing: 10) {
            Text("You said").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 14, height: 1)
            Text("Better").frame(maxWidth: .infinity, alignment: .leading)
            Text(last).frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary).frame(width: 14).accessibilityHidden(true)
    }

    private var rowDivider: some View {
        Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 14)
    }

    private func practiceButton(_ item: SavedCorrection) -> some View {
        Button { controller.practise(item) } label: { Label("Practice this", systemImage: "mic") }
            .disabled(!canPractice || controller.isSaving)
            .help("Say it, then use it in a new sentence")
    }

    private func banner(_ message: String, busy: Bool, retry: @escaping () -> Void) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle").font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry", action: retry).disabled(busy)
        }
        .padding(12)
        .background(Color(nsColor: .systemOrange).opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 14)
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.top, 22)
    }
}

/// An opened row sits on a soft surface so its details read as part of it.
private struct LearningRowSurface: ViewModifier {
    let open: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(open ? Color.primary.opacity(0.035) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
