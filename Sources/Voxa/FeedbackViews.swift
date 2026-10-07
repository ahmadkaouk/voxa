import AppKit
import Combine
import SwiftUI

// Disambiguate the macOS 13 property wrapper from the newer SDK's State macro.
private typealias FeedbackViewState<Value> = SwiftUI.State<Value>

enum FeedbackPalette {
    // Keep the muted original dynamic when a live panel changes appearance.
    static let originalText = NSColor(name: nil) { appearance in
        let base: NSColor = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
        return base.withAlphaComponent(0.72)
    }
    static let addedText = NSColor.systemBlue
    static let added = Color.primary
    static let addedBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemBlue.withAlphaComponent(0.22) : NSColor.systemBlue.withAlphaComponent(0.12)
    }
    static let accent = Color.primary
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

private struct FeedbackPrimaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent).tint(Color(nsColor: .systemBlue)).controlSize(.regular)
        } else {
            content.buttonStyle(FeedbackSaveButtonStyle())
        }
    }
}

private struct FeedbackCardSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.09), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.09), lineWidth: 0.5))
        }
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
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let fontSize: CGFloat = corrected ? 16 : 14
        let text = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: corrected ? NSColor.labelColor : FeedbackPalette.originalText,
            .paragraphStyle: paragraph
        ])
        var offset = 0
        for change in FeedbackWordDiff(original: original, suggestion: suggestion).changes {
            let range = corrected ? NSRange(location: change.range.location + offset, length: (change.suggestion as NSString).length) : change.range
            if range.length > 0 {
                if corrected {
                    text.addAttributes([.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                                        .foregroundColor: NSColor.labelColor,
                                        .backgroundColor: FeedbackPalette.addedBackground], range: range)
                } else {
                    text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
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
    var onLayoutChange: () -> Void = {}
    @FeedbackViewState private var expandedCorrections: Set<[Int]> = []
    static let width: CGFloat = 380

    private var maximumListHeight: CGFloat {
        let chrome: CGFloat = controller.storageError == nil && controller.progress.error == nil ? 190 : 285
        return max(80, maximumHeight - chrome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    grammarSummary
                    ForEach(Array(FeedbackSentence.groups(transcript: controller.transcript,
                            findings: controller.corrections.map(\.feedback)).enumerated()), id: \.element.findingIndices) { index, group in
                        if index > 0 { Divider().opacity(0.5) }
                        correctionGroup(group)
                    }
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
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4).help(error)
                    Button("Retry") { controller.reloadSaved(); controller.progress.retry() }
                        .font(.system(size: 11)).disabled(controller.isSaving || controller.progress.isSaving)
                }
            }
        }
        .padding(20).frame(width: Self.width)
        .modifier(FeedbackCardSurface())
        // The floating panel never becomes key, but its controls must remain readable.
        .environment(\.controlActiveState, .active)
        .onHover { controller.setReading($0) }
        .onChange(of: expandedCorrections) { _ in onLayoutChange() }
        .onChange(of: controller.findings.first?.id) { _ in expandedCorrections.removeAll() }
    }

    private func correctionGroup(_ group: FeedbackSentence.Group) -> some View {
        let items = group.findingIndices.map { controller.corrections[$0] }
        let titles = items.reduce(into: [String]()) { titles, item in
            let title = correctionTitle(item.feedback)
            if !titles.contains(title) { titles.append(title) }
        }
        let title = titles.joined(separator: " · ")
        let expanded = expandedCorrections.contains(group.findingIndices)
        return VStack(alignment: .leading, spacing: 16) {
            sentenceLine("You said", pair: group.sentence, corrected: false)
            sentenceLine("Improved", pair: group.sentence, corrected: true)
            Button {
                if expanded { expandedCorrections.remove(group.findingIndices) }
                else { expandedCorrections.insert(group.findingIndices) }
            } label: {
                HStack {
                    Text(expanded ? "Hide explanation" : "Why this change?")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.font(.system(size: 12, weight: .medium)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color(nsColor: .systemBlue))
            .accessibilityLabel("\(expanded ? "Hide" : "Show") explanation: \(title)")
            .accessibilityValue(expanded ? "Explanation shown" : "Explanation hidden")
            .help(expanded ? "Hide explanation" : "Show why this sentence changed")
            if expanded {
                ForEach(items) { item in
                    correctionExplanation(item, showTitle: items.count > 1)
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func correctionTitle(_ feedback: EnglishFeedback) -> String {
        feedback.focus?.label ?? (feedback.kind == .construction ? "Sentence structure" : "Correction")
    }

    private func correctionExplanation(_ item: SavedCorrection, showTitle: Bool) -> some View {
        let feedback = item.feedback
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                if showTitle { Text(correctionTitle(feedback)).font(.system(size: 12, weight: .medium)) }
                if let focus = feedback.focus, controller.previousOccurrences(of: focus) > 0 {
                    Text("Seen before").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                practiceButton(item)
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Remember")
                Text(feedback.pattern ?? feedback.explanation).font(.system(size: 13, weight: .medium)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
            if feedback.pattern != nil {
                Text(feedback.explanation).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.74)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sentenceLine(_ label: String, pair: FeedbackSentence, corrected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(label)
            FeedbackSentenceText(original: pair.original, suggestion: pair.suggestion, corrected: corrected)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
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
                    sentenceLine("You could say", pair: .init(original: original, suggestion: target.wording), corrected: true)
                    Text(target.alternative ? feedback.alternative!.explanation : feedback.explanation)
                        .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.74)).lineSpacing(3)
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
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
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
                Text("English feedback").font(.system(size: 15, weight: .semibold))
                Text(summary + (controller.contextAppName.map { " · Context: " + $0 } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(controller.contextAppName.map { "Context from " + $0 + ". Nearby text is not saved." } ?? "Full sentences with highlighted corrections. Choose Why this change? for an explanation.")
            }
            Spacer(minLength: 0)
            Button { controller.togglePinned() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12)).frame(width: 26, height: 26)
                    .foregroundStyle(controller.isPinned ? Color(nsColor: .systemBlue) : Color.secondary)
            }.buttonStyle(.plain).disabled(controller.isSaving)
                .help(controller.autoCloseSeconds == 0 ? "Auto-close is set to Never in Settings" :
                    controller.isPinned ? "Unpin to resume automatic dismissal" : "Keep open · Hover to pause the timer")
                .accessibilityLabel(controller.isPinned ? "Unpin feedback" : "Keep feedback open")
            Button { controller.discardReview() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 26, height: 26)
                    .background(.primary.opacity(0.065), in: Circle()).contentShape(Circle())
            }.buttonStyle(.plain).disabled(controller.isSaving)
                .help("Close · \(controller.cancelHotkey.symbolLabel)").accessibilityLabel("Close feedback")
        }
    }

    private func timerLabel(at date: Date) -> String {
        if controller.autoCloseSeconds == 0 { return "Auto-close off" }
        if controller.isPinned { return "Pinned" }
        if controller.isReading || controller.dismissalDeadline == nil { return "Timer pauses while reading" }
        return "Closes in \(max(1, Int(ceil(controller.dismissalDeadline!.timeIntervalSince(date)))))s"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(timerLabel(at: timeline.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 2)
            if controller.hasLessons {
                Button { controller.saveAndClose() } label: {
                    Text(controller.isSaving ? "Saving…" : "Save")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 5)
                }.modifier(FeedbackPrimaryAction())
                    .disabled(controller.isSaving || !controller.storageReady)
                    .help("Save these patterns for later practice · \(controller.saveHotkey.symbolLabel)")
            }
        }
    }

    private var summary: String {
        let errors = controller.corrections.count
        let alternatives = controller.alternatives.count + controller.corrections.filter { $0.feedback.alternative != nil }.count
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) \(errors == 1 ? "correction" : "corrections")") }
        if alternatives > 0 { parts.append("\(alternatives) \(alternatives == 1 ? "alternative" : "alternatives")") }
        return parts.isEmpty ? "A quick look at your dictation" : parts.joined(separator: " · ")
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
        let content = FeedbackReviewView(controller: controller, maximumHeight: frame.height - 110,
                                         onLayoutChange: { [weak self] in self?.scheduleResize() })
        let hosting = FeedbackPanelHostingView(rootView: content)
        self.hosting = hosting; availableFrame = frame
        panel.contentView = hosting
        resize()
        observation = controller.objectWillChange.sink { [weak self] in self?.scheduleResize() }
        panel.orderFrontRegardless() // Never activates Voxa or makes it the paste destination.
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Published values and SwiftUI disclosure state must settle before measuring.
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resize()
        }
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

private final class FeedbackPanelHostingView: NSHostingView<FeedbackReviewView> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: FeedbackReviewView) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
