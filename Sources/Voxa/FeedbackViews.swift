import AppKit
import Combine
import SwiftUI

enum FeedbackPalette {
    static let addedText = NSColor.systemBlue
    static let added = Color.primary
    static let addedBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemBlue.withAlphaComponent(0.22) : NSColor.systemBlue.withAlphaComponent(0.12)
    }
    static let accent = Color.primary
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
                detail("Why", text: explanation, color: .primary)
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

@MainActor
final class FeedbackPanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<FeedbackReviewView>?
    private var availableFrame: NSRect?
    private var screenFrame: NSRect?
    private var observation: AnyCancellable?
    private var resizeScheduled = false

    func show(_ controller: FeedbackController) {
        let panel = panel ?? makePanel()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let content = FeedbackReviewView(controller: controller, maximumHeight: frame.height - 110,
                                         onSizeChange: { [weak self] in self?.scheduleResize() })
        let hosting = FeedbackPanelHostingView(rootView: content)
        self.hosting = hosting; availableFrame = frame
        screenFrame = screen?.frame ?? frame
        panel.contentView = hosting
        resize()
        observation = controller.objectWillChange.sink { [weak self] in self?.scheduleResize() }
        panel.orderFrontRegardless() // Never activates Voxa or makes it the paste destination.
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Published values must settle before measuring.
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resize()
        }
    }

    private func resize() {
        guard let panel, let hosting, let frame = availableFrame else { return }
        let height = min(hosting.fittingSize.height, frame.height - 110)
        let width = FeedbackReviewView.width(for: hosting.rootView.controller)
        panel.setFrame(IslandPresentation.defaultFrame(for: .feedback,
            size: NSSize(width: width, height: height), screenFrame: screenFrame ?? frame,
            visibleFrame: frame), display: true)
    }

    func hide() {
        observation = nil; hosting = nil; availableFrame = nil; screenFrame = nil
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
