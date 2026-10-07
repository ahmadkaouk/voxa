import AppKit
import Combine
import SwiftUI

// Disambiguate the macOS 13 property wrapper from the newer SDK's State macro.
private typealias FeedbackViewState<Value> = SwiftUI.State<Value>

enum FeedbackPalette {
    static let addedText = NSColor.labelColor
    static let added = Color.primary
    static let addedBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.27, alpha: 1) : NSColor(white: 0.89, alpha: 1)
    }
    static let accent = Color.primary
    // One opaque neutral surface keeps every part of the feedback the same color.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.98, alpha: 1)
    })
}

private struct FeedbackSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color(nsColor: .systemBlue).opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// AppKit renders the inline highlights and measures their wrapped text at the
/// proposed width, including in the floating panel and saved-lesson details.
private struct FeedbackComparisonText: NSViewRepresentable {
    let original: String
    let suggestion: String
    let kind: FeedbackKind
    let originalLabel: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.maximumNumberOfLines = 0
        field.font = .systemFont(ofSize: 18)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let difference = FeedbackComparison(original: original, suggestion: suggestion)
        let isFix = kind == .grammar || kind == .construction
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor
        ]
        let text = NSMutableAttributedString()
        func append(_ value: String, attributes: [NSAttributedString.Key: Any] = [:]) {
            text.append(NSAttributedString(string: value, attributes: base.merging(attributes) { _, value in value }))
        }
        func appendChange(_ value: String, attributes: [NSAttributedString.Key: Any]) {
            let wording = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wording.isEmpty else { append(value); return }
            append(String(value.prefix(while: { $0.isWhitespace })))
            append(wording, attributes: attributes)
            append(String(value.reversed().prefix(while: { $0.isWhitespace }).reversed()))
        }
        var oldStyle: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor]
        if isFix { oldStyle[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let newStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: FeedbackPalette.addedText,
            .backgroundColor: FeedbackPalette.addedBackground
        ]
        let removed = difference.removed.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = difference.added.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isFix && (removed.isEmpty || added.isEmpty) {
            // An optional shortening must still show both valid expressions.
            append(original, attributes: oldStyle)
            append(" → ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            append(suggestion, attributes: newStyle)
        } else {
            append(difference.prefix)
            if !removed.isEmpty && !added.isEmpty {
                append(String(difference.added.prefix(while: { $0.isWhitespace })))
                append(removed, attributes: oldStyle)
                append(" → ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
                append(added, attributes: newStyle)
                append(String(difference.added.reversed().prefix(while: { $0.isWhitespace }).reversed()))
            } else {
                appendChange(difference.removed, attributes: oldStyle)
                appendChange(difference.added, attributes: newStyle)
            }
            append(difference.suffix)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        field.attributedStringValue = text
        let result = isFix ? "Corrected" : kind == .phrasing ? "Optional alternative" : "Possible transcription"
        field.setAccessibilityLabel("\(originalLabel): \(original). \(result): \(suggestion)")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 440
        nsView.preferredMaxLayoutWidth = width
        let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size?.height ?? 0))
    }
}

struct FeedbackLessonView: View {
    let feedback: EnglishFeedback
    var previousOccurrences = 0
    // Saved-lesson details retain individual practice links. A live review uses
    // the shared footer so actions never interrupt the explanation.
    var onPractice: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            lesson(original: feedback.original, suggestion: feedback.suggestion, kind: feedback.kind,
                   focus: feedback.focus, explanation: feedback.explanation, pattern: feedback.pattern,
                   practiceAlternative: false)
            if let alternative = feedback.alternative {
                Divider().opacity(0.6)
                // Compare the optional expression with the corrected sentence,
                // so the grammar mistake isn't repeated as a valid alternative.
                lesson(original: feedback.suggestion, suggestion: alternative.wording, kind: .phrasing,
                       focus: alternative.focus, explanation: alternative.explanation, pattern: alternative.pattern,
                       practiceAlternative: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lesson(original: String, suggestion: String, kind: FeedbackKind, focus: LearningFocus?,
                        explanation: String, pattern: String?, practiceAlternative: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(kind == .phrasing ? "Alternative" : kind == .transcriptionIssue ? "Check transcription" : "Fix",
                      systemImage: kind == .phrasing ? "arrow.left.arrow.right" : kind == .transcriptionIssue ? "questionmark.circle" : "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                if let focus {
                    Text(focus.label).foregroundStyle(.secondary)
                } else if kind == .construction {
                    Text("Sentence structure").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if kind == .phrasing {
                    Text("Optional").foregroundStyle(.secondary)
                } else if previousOccurrences > 0, kind != .transcriptionIssue {
                    Text("Recurring · \(previousOccurrences + 1) reviews").foregroundStyle(.secondary)
                        .help("This pattern also appeared in \(previousOccurrences) earlier \(previousOccurrences == 1 ? "review" : "reviews").")
                }
            }.font(.system(size: 11)).accessibilityElement(children: .combine)
            FeedbackComparisonText(original: original, suggestion: suggestion, kind: kind,
                                   originalLabel: practiceAlternative ? "Corrected sentence" : "You said")
            VStack(alignment: .leading, spacing: 6) {
                detail("Why", text: explanation, color: .primary.opacity(0.8))
                if let pattern { detail("Pattern", text: pattern, color: FeedbackPalette.accent) }
            }
            practiceButton(alternative: practiceAlternative)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(color).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func practiceButton(alternative: Bool) -> some View {
        if let onPractice {
            Button { onPractice(alternative) } label: {
                Label("Practice this", systemImage: "mic")
            }.buttonStyle(.link).font(.system(size: 12))
                .accessibilityLabel(alternative ? "Practice this alternative" : "Practice this lesson")
        }
    }
}

/// Keep the complete sentence visible while highlighting only the words that changed.
private struct FeedbackSentenceText: NSViewRepresentable {
    let original: String
    let suggestion: String
    var corrected = true

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let value = corrected ? suggestion : original
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let text = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        var offset = 0
        for change in FeedbackWordDiff(original: original, suggestion: suggestion).changes {
            let range = corrected ? NSRange(location: change.range.location + offset, length: (change.suggestion as NSString).length) : change.range
            if range.length > 0 {
                if corrected {
                    text.addAttributes([.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                        .backgroundColor: FeedbackPalette.addedBackground], range: range)
                } else {
                    text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                        .foregroundColor: NSColor.secondaryLabelColor], range: range)
                }
            }
            offset += (change.suggestion as NSString).length - change.range.length
        }
        field.attributedStringValue = text
        field.setAccessibilityLabel(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 430
        nsView.preferredMaxLayoutWidth = width
        let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size?.height ?? 0))
    }
}

struct FeedbackReviewView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 680
    static let width: CGFloat = 520

    private var maximumListHeight: CGFloat {
        let chrome: CGFloat = controller.storageError == nil && controller.progress.error == nil ? 174 : 250
        return max(80, maximumHeight - chrome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    grammarSummary
                    ForEach(controller.corrections) { item in changeGroup(item) }
                    fullSentences
                    optionalWording
                    ForEach(controller.transcriptionIssues) { item in
                        Divider().opacity(0.6)
                        FeedbackLessonView(feedback: item.feedback)
                    }
                }.padding(.trailing, 4).padding(.vertical, 2)
            }
            .frame(maxHeight: maximumListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .id(controller.findings.first?.id)
            Divider().opacity(0.6)
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
        .background(FeedbackPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.09)))
        .onHover { controller.setReading($0) }
    }

    private func changeGroup(_ item: SavedCorrection) -> some View {
        let feedback = item.feedback
        let changes = FeedbackWordDiff(original: feedback.original, suggestion: feedback.suggestion).changes.filter {
            EnglishText.spokenWords($0.original) != EnglishText.spokenWords($0.suggestion)
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(feedback.focus?.label ?? (feedback.kind == .construction ? "Sentence structure" : "Correction"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let focus = feedback.focus, controller.previousOccurrences(of: focus) > 0 {
                    Text("Seen before").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                practiceButton(item)
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    let before = change.original.trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = change.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(before.isEmpty ? "Add" : before).strikethrough(!before.isEmpty).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(after.isEmpty ? "Remove" : after).fontWeight(.medium)
                }.font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Remember").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(feedback.pattern ?? feedback.explanation).font(.system(size: 12)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
            if feedback.pattern != nil {
                Text(feedback.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var fullSentences: some View {
        let pairs = FeedbackSentence.comparisons(transcript: controller.transcript,
                                                findings: controller.corrections.map(\.feedback))
        if !pairs.isEmpty {
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(pairs.count == 1 ? "Full sentence" : "Full sentences")
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    if index > 0 { Divider().opacity(0.35) }
                    sentenceLine("Before", pair: pair, corrected: false)
                    sentenceLine("After", pair: pair, corrected: true)
                }
            }
        }
    }

    private func sentenceLine(_ label: String, pair: FeedbackSentence, corrected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading).padding(.top, 3)
            FeedbackSentenceText(original: pair.original, suggestion: pair.suggestion, corrected: corrected)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var optionalWording: some View {
        let choices = controller.reviewPracticeTargets.filter { $0.alternative || $0.lesson.feedback.kind == .phrasing }
        if !choices.isEmpty {
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Optional wording")
                ForEach(Array(choices.enumerated()), id: \.offset) { index, target in
                    if index > 0 { Divider().opacity(0.35) }
                    let feedback = target.lesson.feedback
                    let original = target.alternative ? feedback.suggestion : feedback.original
                    if !target.alternative {
                        sentenceLine("You said", pair: .init(original: original, suggestion: original), corrected: false)
                    }
                    FeedbackSentenceText(original: original, suggestion: target.wording)
                    Text(target.alternative ? feedback.alternative!.explanation : feedback.explanation)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline) {
                        if let pattern = target.alternative ? feedback.alternative?.pattern : feedback.pattern {
                            Text("Remember · " + pattern).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        practiceButton(target.lesson, alternative: target.alternative)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    private func practiceButton(_ item: SavedCorrection, alternative: Bool = false) -> some View {
        Button { controller.practise(item, alternative: alternative) } label: {
            Label("Try once", systemImage: "mic").font(.system(size: 11))
        }.buttonStyle(.plain).foregroundStyle(.secondary).fixedSize().disabled(controller.isSaving)
            .help("Practise this pattern in a new sentence.")
    }

    @ViewBuilder private var grammarSummary: some View {
        let noErrors = controller.corrections.isEmpty && controller.transcriptionIssues.isEmpty
        if noErrors || !controller.successfulPatterns.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if noErrors {
                    Label("No clear grammar errors", systemImage: "checkmark.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                if !controller.successfulPatterns.isEmpty {
                    Text("Used well · " + controller.successfulPatterns.map(\.label).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("English feedback").font(.system(size: 16, weight: .semibold))
                Text(summary + (controller.contextAppName.map { " · Context: " + $0 } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(controller.contextAppName.map { "Context from " + $0 + ". Nearby text is not saved." } ?? "Changes first, then the full sentence.")
            }
            Spacer(minLength: 0)
            Button { controller.togglePinned() } label: {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(spacing: 4) {
                        Image(systemName: controller.isPinned ? "pin.fill" : "timer")
                        Text(timerLabel(at: timeline.date))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).disabled(controller.isSaving)
                .help(controller.isPinned ? "Unpin to resume automatic dismissal" : "Keep open · Hover to pause the timer")
                .accessibilityLabel(controller.isPinned ? "Unpin feedback" : "Keep feedback open")
            Button { controller.discardReview() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Circle())
            }.buttonStyle(.plain).disabled(controller.isSaving).help("Close · Esc").accessibilityLabel("Close feedback")
        }
    }

    private func timerLabel(at date: Date) -> String {
        if controller.isPinned { return "Pinned" }
        if controller.isReading || controller.dismissalDeadline == nil { return "Paused" }
        return "\(max(1, Int(ceil(controller.dismissalDeadline!.timeIntervalSince(date)))))s"
    }

    private var footer: some View {
        HStack {
            Button { controller.discardReview() } label: {
                HStack(spacing: 12) { Text("Close"); keycap(FeedbackShortcut.discardLabel) }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.13)))
            }.buttonStyle(.plain).disabled(controller.isSaving)
            Spacer()
            if controller.hasLessons {
                Button { controller.saveAndClose() } label: {
                    HStack(spacing: 16) { Text(controller.isSaving ? "Saving…" : "Save"); keycap(FeedbackShortcut.saveLabel) }
                }.buttonStyle(FeedbackSaveButtonStyle())
                    .disabled(controller.isSaving || !controller.storageReady)
                    .help("Save these patterns for later practice.")
            }
        }.font(.system(size: 12))
    }

    private var summary: String {
        let errors = controller.corrections.count
        let alternatives = controller.alternatives.count + controller.corrections.filter { $0.feedback.alternative != nil }.count
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) \(errors == 1 ? "correction" : "corrections")") }
        if alternatives > 0 { parts.append("\(alternatives) \(alternatives == 1 ? "alternative" : "alternatives")") }
        return parts.isEmpty ? "A quick look at your dictation" : parts.joined(separator: " · ")
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 11)).opacity(0.65)
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
        let content = FeedbackReviewView(controller: controller, maximumHeight: frame.height - 110)
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
        let height = min(hosting.fittingSize.height, frame.height - 110)
        panel.setFrame(NSRect(x: round(frame.midX - FeedbackReviewView.width / 2), y: frame.minY + 80,
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
                    Text("Choose Save after a dictation.\nThen come here to try it in a new sentence.")
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
