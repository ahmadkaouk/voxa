import AppKit
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

struct FeedbackLessonView: View {
    let feedback: EnglishFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if feedback.kind == .phrasing {
                Text(feedback.original).font(.system(size: 12)).foregroundStyle(.secondary)
                alternative(feedback.suggestion, explanation: feedback.explanation, pattern: feedback.pattern,
                            showLabel: false)
            } else if feedback.kind == .transcriptionIssue {
                Text(feedback.original).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(feedback.suggestion).font(.system(size: 15, weight: .medium))
                explanation(feedback.explanation)
            } else {
                correction
                explanation(feedback.explanation)
                if let option = feedback.alternative {
                    alternative(option.wording, explanation: option.explanation, pattern: option.pattern)
                        .padding(.leading, 12).padding(.vertical, 2)
                        .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.12)).frame(width: 2) }
                        .padding(.top, 6)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var correction: some View {
        let diff = FeedbackDifference(original: feedback.original, suggestion: feedback.suggestion)
        if diff.isCompact {
            inline(diff).font(.system(size: 16)).lineSpacing(5)
                .accessibilityLabel("You said: \(feedback.original) Corrected: \(feedback.suggestion)")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("You said · \(feedback.original)").font(.system(size: 12)).foregroundStyle(.secondary)
                diff.suggestion.reduce(Text("")) { result, token in
                    result + (token.changed ? Text(token.text).foregroundColor(FeedbackPalette.added).bold()
                              : Text(token.text))
                }.font(.system(size: 16)).lineSpacing(5)
                    .accessibilityLabel("Corrected: \(feedback.suggestion)")
            }
        }
    }

    private func inline(_ difference: FeedbackDifference) -> Text {
        var result = Text("")
        var previous: FeedbackDifference.InlineToken?
        for token in difference.inline {
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

    private func alternative(_ wording: String, explanation: String, pattern: String?, showLabel: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLabel {
                Text("Another way to say it · Optional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(wording).font(.system(size: 15, weight: .medium)).lineSpacing(3)
            if let pattern {
                Text(pattern).font(.system(size: 11, weight: .medium)).foregroundStyle(FeedbackPalette.accent)
                    .accessibilityLabel("Reusable pattern: \(pattern)")
            }
            self.explanation(explanation)
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
    }
}

struct FeedbackReviewView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 640
    static let width: CGFloat = 480

    private var listHeight: CGFloat {
        let desired: CGFloat = controller.findings.count > 1 ? 360 : (controller.findings.isEmpty ? 80 : 240)
        let footer: CGFloat = controller.storageError == nil && controller.progress.error == nil ? 180 : 220
        return min(desired, max(80, maximumHeight - footer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("English feedback").font(.system(size: 16, weight: .semibold))
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                score
                Button { controller.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Close this English review")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !controller.corrections.isEmpty {
                        section("Corrections", items: controller.corrections)
                    } else if controller.transcriptionIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("No clear grammar errors", systemImage: "checkmark")
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(FeedbackPalette.added)
                            if controller.assessment?.status == .tooShort {
                                Text("A longer sample will give you a grammar estimate.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !controller.alternatives.isEmpty {
                        section("Other ways to say it · Optional", items: controller.alternatives)
                    }
                    if !controller.transcriptionIssues.isEmpty {
                        section("Check the transcription", items: controller.transcriptionIssues)
                    }
                    if !controller.successfulPatterns.isEmpty {
                        Text("Used well: " + controller.successfulPatterns.map(\.label).joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(FeedbackPalette.added)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.trailing, 6).padding(.vertical, 2)
            }
            .frame(height: listHeight)
            .id(controller.findings.first?.id)
            Divider()
            HStack {
                Text(controller.hasLessons ? "Save for later practice" : "Keep practising in your next dictation")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if controller.hasLessons {
                    Button { controller.saveAndClose() } label: {
                        HStack(spacing: 7) { Text("Save lessons"); keycap(FeedbackShortcut.saveLabel) }
                    }
                    .buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
                    .disabled(controller.isSaving || !controller.storageReady)
                    .help("Save the corrections and alternatives. Your inserted text stays unchanged.")
                }
                Button { controller.discardReview() } label: {
                    HStack(spacing: 7) { Text("Close"); keycap(FeedbackShortcut.discardLabel) }
                }.buttonStyle(.bordered).disabled(controller.isSaving)
                    .help("Close without saving lessons. Local progress is kept in Lessons & Progress.")
            }.controlSize(.small)
            if let error = controller.storageError ?? controller.progress.error {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("Retry") { controller.reloadSaved(); controller.progress.retry() }
                        .font(.system(size: 10)).disabled(controller.isSaving || controller.progress.isSaving)
                }
            }
        }
        .padding(20).frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.09)))
    }

    private var summary: String {
        let errors = controller.corrections.count
        let alternatives = controller.alternatives.count + controller.corrections.filter { $0.feedback.alternative != nil }.count
        if errors == 0 && alternatives == 0 { return "A quick look at your dictation" }
        let corrections = "\(errors) \(errors == 1 ? "correction" : "corrections")"
        guard alternatives > 0 else { return corrections }
        return corrections + " · \(alternatives) \(alternatives == 1 ? "alternative" : "alternatives")"
    }

    @ViewBuilder private var score: some View {
        if let assessment = controller.assessment {
            if let band = assessment.band {
                VStack(alignment: .trailing, spacing: 2) {
                    (Text("\(band.rawValue)").font(.system(size: 23, weight: .medium, design: .rounded))
                     + Text(" / 10").font(.system(size: 11)).foregroundColor(.secondary))
                    Text("Grammar estimate").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .help("\(band.label). \(assessment.explanation)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Grammar estimate: \(band.rawValue) out of 10. \(band.label). \(assessment.explanation)")
            } else {
                Text(assessment.status == .tooShort ? "Short sample" : "Unscored")
                    .font(.system(size: 10)).foregroundStyle(.secondary).help(assessment.explanation)
                    .accessibilityLabel(assessment.explanation)
            }
        }
    }

    private func section(_ title: String, items: [SavedCorrection]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().opacity(0.6) }
                VStack(alignment: .leading, spacing: 7) {
                    FeedbackLessonView(feedback: item.feedback)
                    if let focus = item.feedback.focus, focus.isGrammar,
                       item.feedback.kind != .phrasing, controller.previousOccurrences(of: focus) > 0 {
                        let count = controller.previousOccurrences(of: focus)
                        Text("\(focus.label) · also seen in \(count) earlier \(count == 1 ? "review" : "reviews")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 9, weight: .medium, design: .monospaced)).opacity(0.7)
    }
}

@MainActor
final class FeedbackPanelController {
    private var panel: NSPanel?

    func show(_ controller: FeedbackController) {
        let panel = panel ?? makePanel()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let content = FeedbackReviewView(controller: controller, maximumHeight: frame.height - 90)
        let hosting = NSHostingView(rootView: content)
        let height = min(hosting.fittingSize.height, frame.height - 90)
        // Keep long findings usable on small displays, without truncating the explanation.
        panel.contentView = NSHostingView(rootView: content.frame(height: height, alignment: .top))
        panel.setFrame(NSRect(x: round(frame.midX - FeedbackReviewView.width / 2), y: frame.minY + 56,
                             width: FeedbackReviewView.width, height: height), display: true)
        panel.orderFrontRegardless() // Never activates Voxa or makes it the paste destination.
    }

    func hide() { panel?.orderOut(nil) }

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

    var body: some View {
        TabView {
            SavedLessonsView(controller: controller).tabItem { Text("Saved lessons") }
            LearningProgressView(progress: controller.progress).tabItem { Text("Progress") }
        }.padding(12)
    }
}

private struct SavedLessonsView: View {
    @ObservedObject var controller: FeedbackController
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
                        CorrectionDetailView(item: item, isSaving: controller.isSaving) { controller.delete(item.id) }
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
    let onDelete: () -> Void
    @FeedbackViewState private var practising = false
    @FeedbackViewState private var answer = ""
    @FeedbackViewState private var reveal = false
    @FocusState private var writing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(practising ? "MAKE IT YOURS" : "YOUR LESSON")
                        .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(isSaving).accessibilityLabel("Delete this lesson")
                }
                if practising {
                    Text(item.feedback.practicePrompt).font(.system(size: 19, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $answer)
                        .font(.system(size: 15)).padding(8)
                        .frame(height: 130)
                        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
                        .focused($writing)
                        .accessibilityLabel("Write your new sentence")
                    Text("For your own practice. Your answer isn’t sent or saved.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(reveal ? "Hide lesson" : "Show lesson") { reveal.toggle() }
                        Spacer()
                        Button("Done") { practising = false; answer = ""; reveal = false }
                    }
                    if reveal { FeedbackLessonView(feedback: item.feedback) }
                } else {
                    FeedbackLessonView(feedback: item.feedback)
                    Button { practising = true; writing = true } label: {
                        Label("Practise a new sentence", systemImage: "pencil.line")
                    }
                    .buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
                }
            }.padding(26)
        }
        .onDisappear { answer = "" }
    }
}
