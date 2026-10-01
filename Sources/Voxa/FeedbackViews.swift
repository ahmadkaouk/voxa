import AppKit
import Combine
import SwiftUI

// Disambiguate the macOS 13 property wrapper from the newer SDK's State macro.
private typealias FeedbackViewState<Value> = SwiftUI.State<Value>

enum FeedbackPalette {
    static let added = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.40, green: 0.85, blue: 0.62, alpha: 1)
            : NSColor(red: 0.12, green: 0.44, blue: 0.28, alpha: 1)
    })
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.42, green: 0.81, blue: 0.84, alpha: 1)
            : NSColor(red: 0.12, green: 0.40, blue: 0.45, alpha: 1)
    })
}

private struct FeedbackSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(FeedbackPalette.accent)
            .background(FeedbackPalette.accent.opacity(configuration.isPressed ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FeedbackPalette.accent.opacity(0.15)))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct FeedbackLessonView: View {
    let feedback: EnglishFeedback
    // Saved-lesson details retain individual practice links. A live review uses
    // the shared footer so actions never interrupt the explanation.
    var onPractice: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if feedback.kind == .phrasing {
                alternative(feedback.suggestion, explanation: feedback.explanation, pattern: feedback.pattern,
                            original: feedback.original, practiceAlternative: false)
            } else if feedback.kind == .transcriptionIssue {
                Text(feedback.original).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(feedback.suggestion).font(.system(size: 16, weight: .medium))
                explanation(feedback.explanation)
            } else {
                correction
                explanation(feedback.explanation)
                practiceButton(alternative: false)
                if let option = feedback.alternative {
                    alternative(option.wording, explanation: option.explanation, pattern: option.pattern,
                                practiceAlternative: true)
                        .padding(.top, 2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func practiceButton(alternative: Bool) -> some View {
        if let onPractice {
            Button { onPractice(alternative) } label: {
                Label("Practice this", systemImage: "mic")
            }.buttonStyle(.link).font(.system(size: 12))
                .accessibilityLabel(alternative ? "Practice this alternative" : "Practice this lesson")
        }
    }

    private var correction: some View {
        let diff = FeedbackDifference(original: feedback.original, suggestion: feedback.suggestion)
        return inline(diff).font(.system(size: 17)).lineSpacing(4)
            .accessibilityLabel("You said: \(feedback.original). Corrected: \(feedback.suggestion)")
    }

    private func inline(_ difference: FeedbackDifference) -> Text {
        var result = Text("")
        var previous: FeedbackDifference.InlineToken?
        for token in difference.inline {
            // Replacements may share no whitespace in the token diff. Keep the
            // struck-through original and its replacement visually separate.
            if previous?.change == .removed, token.change == .added,
               previous?.text.last?.isWhitespace == false, token.text.first?.isWhitespace == false {
                result = result + Text(" ")
            }
            switch token.change {
            case .unchanged: result = result + Text(token.text)
            case .removed: result = result + Text(token.text).foregroundColor(.secondary).strikethrough()
            case .added: result = result + Text(token.text).foregroundColor(FeedbackPalette.added).bold()
            }
            previous = token
        }
        return result
    }

    private func alternative(_ wording: String, explanation: String, pattern: String?,
                             original: String? = nil, practiceAlternative: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Another way to say it")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("Optional").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.045), in: Capsule())
                }
                Text(wording).font(.system(size: 17, weight: .medium)).lineSpacing(4)
                    .accessibilityLabel("Another way to say it: \(wording)")
            }
            if let pattern {
                VStack(alignment: .leading, spacing: 5) {
                    detailLabel("Pattern to reuse")
                    Text(pattern).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FeedbackPalette.accent).lineSpacing(3)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(FeedbackPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 5) {
                detailLabel("Why it works")
                Text(explanation).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8)).lineSpacing(3)
            }.accessibilityElement(children: .combine)
            if let original {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 5) {
                    detailLabel("You said")
                    Text(original).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                }.accessibilityElement(children: .combine)
            }
            practiceButton(alternative: practiceAlternative)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
    }

    private func detailLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func explanation(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Why").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8)).lineSpacing(3)
        }
    }
}

struct FeedbackReviewView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 640
    static let width: CGFloat = 480

    private var maximumListHeight: CGFloat {
        let chrome: CGFloat = controller.storageError == nil && controller.progress.error == nil ? 180 : 240
        return max(80, maximumHeight - chrome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !controller.corrections.isEmpty {
                        corrections
                    }
                    grammarSummary
                    if !controller.alternatives.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(controller.alternatives) { item in
                                FeedbackLessonView(feedback: item.feedback)
                            }
                        }
                    }
                    if !controller.transcriptionIssues.isEmpty {
                        section("Check the transcription", items: controller.transcriptionIssues)
                    }
                }.padding(.trailing, 6).padding(.vertical, 2)
            }
            // Use the native scroll view's ideal content size for a short review.
            // Only long reviews fill this limit and need to scroll.
            .frame(maxHeight: maximumListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .id(controller.findings.first?.id)
            Divider()
            footer
            if let error = controller.storageError ?? controller.progress.error {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Retry") { controller.reloadSaved(); controller.progress.retry() }
                        .font(.system(size: 11)).disabled(controller.isSaving || controller.progress.isSaving)
                }
            }
        }
        .padding(20).frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.09)))
    }

    @ViewBuilder private var grammarSummary: some View {
        let noErrors = controller.corrections.isEmpty && controller.transcriptionIssues.isEmpty
        if noErrors || !controller.successfulPatterns.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if noErrors {
                    Label("No clear grammar errors", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(FeedbackPalette.added)
                }
                if !controller.successfulPatterns.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("Used well:").fontWeight(.medium).fixedSize()
                        Text(controller.successfulPatterns.map(\.label).joined(separator: " · "))
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, noErrors ? 20 : 0)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("English feedback").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 6) {
                    Text(summary).lineLimit(1)
                    if let appName = controller.contextAppName {
                        Text("·")
                        Label("Context: " + appName, systemImage: "text.alignleft")
                            .lineLimit(1).truncationMode(.tail)
                            .help("Context from \(appName). Nearby text helped interpret your dictation; it isn’t saved locally or counted toward your English level.")
                            .accessibilityLabel("Context from \(appName)")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            score
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { controller.discardReview() } label: {
                HStack(spacing: 6) { Text("Close"); keycap(FeedbackShortcut.discardLabel) }
            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(controller.isSaving)
                .help("Close without saving lessons. Local progress is kept in Lessons & Progress.")
            Spacer(minLength: 0)
            practiceAction
            if controller.hasLessons {
                Button { controller.saveAndClose() } label: {
                    HStack(spacing: 7) { Text("Save lessons"); keycap(FeedbackShortcut.saveLabel) }
                }
                .buttonStyle(FeedbackSaveButtonStyle())
                .disabled(controller.isSaving || !controller.storageReady)
                .help("Save the corrections and alternatives for later practice. Your inserted text stays unchanged.")
            }
        }.controlSize(.regular).font(.system(size: 12))
    }

    @ViewBuilder private var practiceAction: some View {
        let choices = controller.reviewPracticeTargets
        if let only = choices.first, choices.count == 1 {
            Button { controller.practise(only.lesson, alternative: only.alternative) } label: {
                Label("Practice this", systemImage: "mic")
            }.buttonStyle(.bordered).disabled(controller.isSaving)
                .help("Try this pattern now. Return here afterward to save the lesson.")
        } else if choices.count > 1 {
            Menu {
                if !controller.corrections.isEmpty {
                    Section("Corrections") {
                        ForEach(controller.corrections) { item in
                            practiceChoice(PracticeTarget(lesson: item, alternative: false))
                        }
                    }
                }
                let alternatives = choices.dropFirst(controller.corrections.count)
                if !alternatives.isEmpty {
                    Section("Alternative phrasing") {
                        ForEach(Array(alternatives.enumerated()), id: \.offset) { _, target in
                            practiceChoice(target)
                        }
                    }
                }
            } label: { Label("Practice this", systemImage: "mic") }
                .menuStyle(.borderedButton).fixedSize().disabled(controller.isSaving)
                .help("Choose a correction or alternative to practice.")
        }
    }

    private func practiceChoice(_ target: PracticeTarget) -> some View {
        Button(String(target.wording.prefix(80)) + (target.wording.count > 80 ? "…" : "")) {
            controller.practise(target.lesson, alternative: target.alternative)
        }.accessibilityLabel(target.wording).help(target.wording)
    }

    private var summary: String {
        let errors = controller.corrections.count
        let alternatives = controller.alternatives.count + controller.corrections.filter { $0.feedback.alternative != nil }.count
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) \(errors == 1 ? "correction" : "corrections")") }
        if alternatives > 0 { parts.append("\(alternatives) \(alternatives == 1 ? "alternative" : "alternatives")") }
        return parts.isEmpty ? "A quick look at your dictation" : parts.joined(separator: " · ")
    }

    private var score: some View {
        let profile = controller.progress.expressionProfile
        return Label(profile.ready ? "≈ " + profile.label : "Learning your level", systemImage: "chart.bar")
            .font(.system(size: profile.ready ? 13 : 10, weight: .medium, design: .rounded))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 6)
            .background(.primary.opacity(0.04), in: Capsule())
            .help((profile.ready ? profile.coverage : profile.guidance) + " " + ExpressionProfile.limitation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("English expression across dictations: \(profile.label). \(profile.coverage). \(ExpressionProfile.limitation)")
    }

    private var corrections: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(controller.corrections.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().opacity(0.6) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(item.feedback.focus?.label ?? "Correction")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        if let focus = item.feedback.focus, focus.isGrammar,
                           controller.previousOccurrences(of: focus) > 0 {
                            let count = controller.previousOccurrences(of: focus)
                            Label("Recurring · \(count + 1) reviews", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .help("This pattern also appeared in \(count) earlier \(count == 1 ? "review" : "reviews").")
                        }
                    }.foregroundStyle(.secondary)
                    FeedbackLessonView(feedback: item.feedback)
                }
            }
        }
    }

    private func section(_ title: String, items: [SavedCorrection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().opacity(0.6) }
                FeedbackLessonView(feedback: item.feedback)
            }
        }
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 10, weight: .medium, design: .monospaced)).opacity(0.7)
    }
}

@MainActor
final class FeedbackPanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<FeedbackReviewView>?
    private var availableFrame: NSRect?
    private var observation: AnyCancellable?
    private var resizeScheduled = false

    func show(_ controller: FeedbackController) {
        let panel = panel ?? makePanel()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let content = FeedbackReviewView(controller: controller, maximumHeight: frame.height - 90)
        let hosting = NSHostingView(rootView: content)
        self.hosting = hosting; availableFrame = frame
        panel.contentView = hosting
        resize()
        observation = controller.objectWillChange.sink { [weak self] in
            guard let self, !self.resizeScheduled else { return }
            self.resizeScheduled = true
            // Published values change after objectWillChange. Refit on the next
            // main turn so a save error or late progress update cannot be clipped.
            DispatchQueue.main.async { [weak self] in
                self?.resizeScheduled = false
                self?.resize()
            }
        }
        panel.orderFrontRegardless() // Never activates Voxa or makes it the paste destination.
    }

    private func resize() {
        guard let panel, let hosting, let frame = availableFrame else { return }
        let height = min(hosting.fittingSize.height, frame.height - 90)
        panel.setFrame(NSRect(x: round(frame.midX - FeedbackReviewView.width / 2), y: frame.minY + 56,
                             width: FeedbackReviewView.width, height: height), display: true)
    }

    func hide() {
        observation = nil; hosting = nil; availableFrame = nil
        panel?.orderOut(nil); panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}

struct SavedCorrectionsView: View {
    @ObservedObject var controller: FeedbackController
    var onShortReview: (() -> Void)? = nil

    var body: some View {
        TabView {
            SavedLessonsView(controller: controller, onShortReview: onShortReview).tabItem { Text("Saved lessons") }
            LearningProgressView(progress: controller.progress).tabItem { Text("Progress") }
        }.padding(12)
    }
}

private struct SavedLessonsView: View {
    @ObservedObject var controller: FeedbackController
    let onShortReview: (() -> Void)?
    @FeedbackViewState private var selection: UUID?
    @FeedbackViewState private var confirmDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A little better, every day.").font(.system(size: 21, weight: .semibold))
                    Text("Your saved English lessons · Stored on this Mac")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if let onShortReview {
                    Button("One-minute review", action: onShortReview)
                        .disabled(controller.saved.isEmpty)
                }
                if !controller.saved.isEmpty {
                    Button("Delete all…") { confirmDeleteAll = true }
                        .disabled(controller.isSaving)
                }
            }
            .padding(24)
            Divider()
            if let error = controller.storageError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                    if !controller.storageReady {
                        Button("Retry") { controller.reloadSaved() }.disabled(controller.isSaving)
                    }
                }.padding()
            }
            if controller.saved.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "bookmark").font(.system(size: 32, weight: .light)).foregroundStyle(FeedbackPalette.accent)
                    Text(controller.isSaving ? "Opening your lessons…" : "Keep the lessons that click.")
                        .font(.system(size: 18, weight: .medium))
                    Text("Choose Save lessons after a dictation.\nThen come here to try it in a new sentence.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(controller.saved, selection: $selection) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.feedback.suggestion).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack {
                                Text(item.feedback.kind.label)
                                Spacer()
                                Text(item.date, style: .date)
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).tag(item.id)
                    }
                    .listStyle(.sidebar).frame(minWidth: 210, idealWidth: 240, maxWidth: 290)
                    if let item = controller.saved.first(where: { $0.id == selection }) {
                        CorrectionDetailView(item: item, isSaving: controller.isSaving,
                                             onPractice: { controller.practise(item, alternative: $0) },
                                             onDelete: { controller.delete(item.id) })
                            .id(item.id)
                            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Choose a lesson to review or practise.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 600)
        .onAppear { selection = controller.saved.first?.id }
        .onChange(of: controller.saved) { items in
            if !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
        }
        .alert("Delete all saved lessons?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { controller.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes your saved corrections from this Mac.") }
    }
}

private struct CorrectionDetailView: View {
    let item: SavedCorrection
    let isSaving: Bool
    let onPractice: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("YOUR LESSON")
                        .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(isSaving).accessibilityLabel("Delete this lesson")
                }
                FeedbackLessonView(feedback: item.feedback, onPractice: onPractice)
            }.padding(26)
        }
    }
}
