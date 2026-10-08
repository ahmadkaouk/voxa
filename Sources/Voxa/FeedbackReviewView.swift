import AppKit
import SwiftUI

/// A compact reading surface with explanations revealed inside the review.
private enum FeedbackNote: Identifiable {
    case correction(FeedbackSentence.Group, [SavedCorrection])
    case alternative(PracticeTarget)
    case transcription(SavedCorrection)

    var id: String {
        switch self {
        case .correction(_, let items): return items.map { $0.id.uuidString }.joined(separator: ":")
        case .alternative(let target): return "alternative-" + target.lesson.id.uuidString
        case .transcription(let item): return "transcription-" + item.id.uuidString
        }
    }
}

private typealias FeedbackViewState<Value> = SwiftUI.State<Value>

struct FeedbackReviewView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 680
    var island = false
    var embeddedInIsland = false
    var onKeepOpen: (() -> Void)? = nil
    var onSizeChange: (() -> Void)? = nil
    var onMove: ((CGPoint, CGPoint, Bool) -> Void)? = nil
    static let width: CGFloat = 480

    @MainActor static func isCompactReview(_ controller: FeedbackController) -> Bool {
        !controller.hasLessons && controller.transcriptionIssues.isEmpty
            && controller.storageError == nil && controller.progress.error == nil && !controller.isSaving
    }

    @MainActor static func width(for controller: FeedbackController) -> CGFloat {
        isCompactReview(controller) ? 400 : width
    }

    private var compact: Bool { Self.isCompactReview(controller) }
    @FeedbackViewState private var retainedLesson: String?
    @FeedbackViewState private var measuredExplanationHeight: CGFloat = 0

    private var activeLesson: String? { retainedLesson }

    private var notes: [FeedbackNote] {
        let corrections = controller.corrections
        let groups = FeedbackSentence.groups(transcript: controller.transcript, findings: corrections.map(\.feedback))
        return groups.map { .correction($0, $0.findingIndices.map { corrections[$0] }) }
            + controller.reviewPracticeTargets.filter { $0.alternative || $0.lesson.feedback.kind == .phrasing }.map(FeedbackNote.alternative)
            + controller.transcriptionIssues.map(FeedbackNote.transcription)
    }

    private var error: String? { controller.storageError ?? controller.progress.error }
    // Only reserve the space used by an explicitly opened explanation. Short
    // teaching points fit naturally; unusually long ones scroll within the cap.
    private var maximumExplanationHeight: CGFloat {
        let available = max(0, maximumHeight - 172)
        let minimumReading = min(100, available / 2)
        return min(110, available - minimumReading)
    }
    private var explanationRegionHeight: CGFloat {
        activeNote == nil ? 0 : min(measuredExplanationHeight, maximumExplanationHeight) + 8
    }
    private var readingHeight: CGFloat {
        max(0, maximumHeight - 172 - explanationRegionHeight)
    }

    private var activeNote: FeedbackNote? {
        guard let activeLesson else { return nil }
        return notes.first { note in
            switch note {
            case .correction(_, let items): return items.contains { lessonKey($0, noteID: note.id) == activeLesson }
            case .alternative: return note.id == activeLesson
            case .transcription: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if compact {
                ViewThatFits(in: .vertical) {
                    cleanReview.fixedSize(horizontal: false, vertical: true)
                    ScrollView(showsIndicators: false) { cleanReview }
                }
                .frame(maxHeight: min(520, max(100, maximumHeight - 126)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.bottom, 16)
            } else {
                ViewThatFits(in: .vertical) {
                    // Measure the complete reading surface before introducing a scroll
                    // viewport. Opening an explanation uses its measured height.
                    reviewNotes.fixedSize(horizontal: false, vertical: true)
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) { reviewNotes }
                            .onAppear {
                                if let retainedID = controller.selectedReviewNoteID {
                                    DispatchQueue.main.async { proxy.scrollTo(retainedID, anchor: .top) }
                                }
                            }
                    }
                }
                .frame(maxHeight: readingHeight)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
            }
            if activeNote != nil {
                explanationWell
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
            if compact { compactFooter } else { footer }
        }
        .frame(width: Self.width(for: controller))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FeedbackReviewHeight.self, value: geometry.size.height)
        })
        .onPreferenceChange(FeedbackReviewHeight.self) { _ in onSizeChange?() }
        .modifier(FeedbackReadingSurface(island: island, embedded: embeddedInIsland))
        .environment(\.controlActiveState, .active)
        .tint(Color(nsColor: FeedbackInk.added))
        .onAppear { retainedLesson = controller.selectedReviewExplanationID }
        .onChange(of: activeLesson) { _ in onSizeChange?() }
        .onChange(of: controller.findings.first?.id) { _ in
            retainedLesson = nil; measuredExplanationHeight = 0
        }
    }

    private var reviewNotes: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error { recovery(error) }
            if notes.isEmpty { cleanReview }
            else {
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                    if index > 0 { Divider().overlay(.primary.opacity(0.04)) }
                    noteContent(note).id(note.id)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12, weight: .medium))
                Text("English feedback").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
            }
            .modifier(IslandMoveHandle(onMove: onMove))
            .help(onMove == nil ? "English feedback" : "Drag to move Voxa")
            Button { controller.discardReview() } label: { Image(systemName: "xmark") }
                .buttonStyle(FeedbackIconButtonStyle()).disabled(controller.isSaving)
                .accessibilityLabel("Close feedback").help("Close · \(controller.cancelHotkey.symbolLabel)")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, compact ? 20 : 28).padding(.trailing, compact ? 14 : 18)
        .padding(.top, compact ? 12 : 18).padding(.bottom, compact ? 12 : 20)
    }

    @ViewBuilder private func noteContent(_ note: FeedbackNote) -> some View {
        switch note {
        case .correction(let group, let items):
            let edits = FeedbackEditPresentation(original: group.sentence.original, suggestion: group.sentence.suggestion)
            let mapping = FeedbackLessonMapping.lessonIndices(original: group.sentence.original,
                suggestion: group.sentence.suggestion, lessons: items.map(\.feedback))
            let selectedIndex = items.indices.first { activeLesson == lessonKey(items[$0], noteID: note.id) }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(items.count > 1 ? "\(items.count) corrections" : (items.first?.feedback.focus?.label ?? "A clearer sentence"))
                        .font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if notes.count > 1 { category("Correction") }
                    if let first = items.first {
                        explanationToggle("Why this change?", expanded: activeNote?.id == note.id) {
                            if activeNote?.id == note.id { closeExplanation() }
                            else { selectLesson(lessonKey(first, noteID: note.id)) }
                        }
                        .accessibilityLabel("Show correction explanations")
                    }
                }
                if edits.usesInlineEdits {
                    FeedbackMarkedText(original: group.sentence.original, suggestion: group.sentence.suggestion, mode: .inline,
                        activeRuns: Set(mapping.filter { $0.value == selectedIndex }.map(\.key)),
                        interactiveRuns: Set(mapping.keys),
                        onSelect: { run in
                            if let index = mapping[run] { retain(lessonKey(items[index], noteID: note.id)) }
                        })
                } else {
                    comparison(original: group.sentence.original, suggestion: group.sentence.suggestion,
                               originalLabel: "You said", suggestionLabel: "Say this", marksChanges: true)
                }
            }
        case .alternative(let target):
            let feedback = target.lesson.feedback
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Another way to say it").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    category("Optional")
                    explanationToggle("Why this wording", expanded: activeLesson == note.id) { retain(note.id) }
                }
                comparison(original: target.alternative ? feedback.suggestion : feedback.original,
                           suggestion: target.wording,
                           originalLabel: target.alternative ? "Corrected sentence" : "You said",
                           suggestionLabel: "You could say", marksChanges: false)
            }
        case .transcription(let item):
            VStack(alignment: .leading, spacing: 16) {
                Label("Check the transcription", systemImage: "waveform")
                    .font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                comparison(original: item.feedback.original, suggestion: item.feedback.suggestion,
                           originalLabel: "Transcribed", suggestionLabel: "Did you mean?", marksChanges: false)
                Text(item.feedback.explanation).font(.system(size: 12)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Check what you said before using this wording.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explanationWell: some View {
        ViewThatFits(in: .vertical) {
            explanationContent
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    explanationContent
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .id("explanation-top")
                }
                .onChange(of: activeLesson) { _ in
                    proxy.scrollTo("explanation-top", anchor: .top)
                }
            }
        }
        .frame(maxHeight: maximumExplanationHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FeedbackExplanationHeight.self, value: geometry.size.height)
        })
        .onPreferenceChange(FeedbackExplanationHeight.self) { measuredExplanationHeight = $0 }
        .background(Color(nsColor: FeedbackInk.added).opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color(nsColor: FeedbackInk.added).opacity(0.13), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Correction explanation")
    }

    @ViewBuilder private var explanationContent: some View {
        if let note = activeNote {
            switch note {
            case .correction(_, let items):
                if let selectedIndex = items.indices.first(where: { activeLesson == lessonKey(items[$0], noteID: note.id) }) {
                    let item = items[selectedIndex]
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: retainedLesson == activeLesson ? "pin.fill" : "sparkle")
                                .foregroundStyle(Color(nsColor: FeedbackInk.added))
                            Text(lessonCue(item.feedback)).fontWeight(.semibold)
                            Spacer(minLength: 4)
                            if items.count > 1 {
                                Text("\(selectedIndex + 1)/\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                                Button { selectLesson(lessonKey(items[(selectedIndex + items.count - 1) % items.count], noteID: note.id)) } label: {
                                    Image(systemName: "chevron.left")
                                }.buttonStyle(FeedbackIconButtonStyle(size: 24)).accessibilityLabel("Previous explanation")
                                Button { selectLesson(lessonKey(items[(selectedIndex + 1) % items.count], noteID: note.id)) } label: {
                                    Image(systemName: "chevron.right")
                                }.buttonStyle(FeedbackIconButtonStyle(size: 24)).accessibilityLabel("Next explanation")
                            }
                            closeExplanationButton
                        }.font(.system(size: 11))
                        teaching(item.feedback.explanation, pattern: item.feedback.pattern, cue: nil,
                                 recurring: item.feedback.focus.map { controller.previousOccurrences(of: $0) } ?? 0,
                                 target: PracticeTarget(lesson: item, alternative: false), noteID: note.id)
                    }
                }
            case .alternative(let target):
                let feedback = target.lesson.feedback
                let alternative = target.alternative ? feedback.alternative : nil
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: retainedLesson == activeLesson ? "pin.fill" : "sparkle")
                            .foregroundStyle(Color(nsColor: FeedbackInk.added))
                        Text("Why this wording").fontWeight(.semibold)
                        Spacer(minLength: 4)
                        closeExplanationButton
                    }.font(.system(size: 11))
                    teaching(alternative?.explanation ?? feedback.explanation,
                             pattern: alternative?.pattern ?? (target.alternative ? nil : feedback.pattern),
                             cue: nil, recurring: 0, target: target, noteID: note.id)
                }
            case .transcription:
                EmptyView()
            }
        }
    }

    private func explanationToggle(_ label: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("Why?")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private var closeExplanationButton: some View {
        Button { closeExplanation() } label: { Image(systemName: "xmark") }
            .buttonStyle(FeedbackIconButtonStyle(size: 24)).accessibilityLabel("Close explanation")
    }

    private func lessonKey(_ item: SavedCorrection, noteID: String) -> String { noteID + ":" + item.id.uuidString }

    private func retain(_ id: String) {
        if retainedLesson == id { closeExplanation() }
        else { selectLesson(id) }
    }

    private func selectLesson(_ id: String) {
        onKeepOpen?()
        retainedLesson = id
    }

    private func closeExplanation() {
        controller.selectedReviewExplanationID = nil
        retainedLesson = nil
    }

    private func category(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.primary.opacity(0.05), in: Capsule())
    }

    private func comparison(original: String, suggestion: String, originalLabel: String,
                            suggestionLabel: String, marksChanges: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(originalLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(original).font(.system(size: 12)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 7) {
                Label(suggestionLabel, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: FeedbackInk.added))
                FeedbackMarkedText(original: original, suggestion: suggestion, mode: marksChanges ? .improved : .suggestion)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: FeedbackInk.addedBackground).opacity(0.5))
        }
        .background(.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.065), lineWidth: 0.5))
    }

    private func lessonCue(_ feedback: EnglishFeedback) -> String {
        let edits = FeedbackEditPresentation(original: feedback.original, suggestion: feedback.suggestion).runs.compactMap { run -> (String, String)? in
            if case .change(let before, let after) = run { return (before, after) }
            return nil
        }
        if edits.count == 1, let edit = edits.first {
            let before = edit.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let after = edit.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if before.count + after.count <= 46 {
                if before.isEmpty { return "Add “" + after + "”" }
                if after.isEmpty { return "Remove “" + before + "”" }
                return before + " → " + after
            }
        }
        return feedback.focus?.label ?? "Sentence structure"
    }

    private func teaching(_ explanation: String, pattern: String?, cue: String?, recurring: Int,
                          target: PracticeTarget, noteID: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                if let cue { Text(cue).font(.system(size: 12, weight: .semibold)) }
                Text(explanation).font(.system(size: 12)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let pattern {
                    (Text("Remember  ").foregroundColor(.secondary) + Text(pattern).fontWeight(.medium))
                        .font(.system(size: 11)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                if recurring > 0 {
                    Text("Seen in earlier feedback").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if controller.reviewPracticeTargets.count > 1 {
                Button { practise(target, noteID: noteID) } label: { Image(systemName: "mic").font(.system(size: 12)) }
                    .buttonStyle(FeedbackIconButtonStyle(size: 30)).disabled(controller.isSaving)
                    .help("Practise: " + target.wording).accessibilityLabel("Practise: " + target.wording)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func practise(_ target: PracticeTarget, noteID: String) {
        controller.selectedReviewNoteID = noteID
        controller.selectedReviewExplanationID = target.alternative || target.lesson.feedback.kind == .phrasing
            ? noteID : lessonKey(target.lesson, noteID: noteID)
        controller.practise(target.lesson, alternative: target.alternative)
    }

    private var cleanReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(nsColor: FeedbackInk.added))
                    .frame(width: 32, height: 32)
                    .background(Color(nsColor: FeedbackInk.addedBackground).opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                        Color(nsColor: FeedbackInk.added).opacity(0.18), lineWidth: 0.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.assessment?.band == .accurate ? "Looking good." : "You're all set.")
                        .font(.system(size: 18, weight: .semibold)).tracking(-0.2)
                        .accessibilityAddTraits(.isHeader)
                    Text("No corrections this time.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("YOUR DICTATION").font(.system(size: 9, weight: .medium))
                        .tracking(1).foregroundStyle(.secondary)
                    Text(controller.transcript).font(.system(size: 13)).lineSpacing(2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
            }
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 12) {
            if let app = controller.contextAppName, !app.isEmpty {
                Text(app).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { controller.discardReview() } label: {
                HStack(spacing: 9) {
                    Text("Done")
                    Text(controller.cancelHotkey.symbolLabel)
                        .font(.system(size: 11, weight: .medium)).opacity(0.65)
                }
            }
            .buttonStyle(FeedbackCommitButtonStyle()).help("Close feedback")
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    private func recovery(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(controller.storageError != nil ? "Your review is still here" : "Progress couldn't be saved",
                  systemImage: "exclamationmark.circle").font(.system(size: 12, weight: .semibold))
            Text(message).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                if controller.storageError != nil {
                    if controller.storageReady { controller.saveAndClose() }
                    else { controller.reloadSaved() }
                }
                if controller.progress.error != nil { controller.progress.retry() }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .disabled(controller.isSaving || controller.progress.isSaving)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .systemOrange).opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
            HStack(spacing: 12) {
                if controller.reviewPracticeTargets.count == 1, let target = controller.reviewPracticeTargets.first,
                   let note = notes.first {
                    Button { practise(target, noteID: note.id) } label: {
                        Label("Practice", systemImage: "mic").font(.system(size: 12, weight: .medium))
                            .padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(controller.isSaving)
                } else if controller.hasLessons {
                    Text("\(controller.corrections.count + controller.reviewPracticeTargets.filter { $0.alternative || $0.lesson.feedback.kind == .phrasing }.count) lessons")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    if controller.hasLessons { controller.saveAndClose() }
                    else { controller.discardReview() }
                } label: {
                    HStack(spacing: 9) {
                        if controller.isSaving { ProgressView().controlSize(.mini) }
                        Text(controller.hasLessons ? (controller.isSaving ? (controller.storageReady ? "Saving…" : "Loading…") : "Save review") : "Done")
                        if !controller.isSaving {
                            Text(controller.hasLessons ? controller.saveHotkey.symbolLabel : controller.cancelHotkey.symbolLabel)
                                .font(.system(size: 11, weight: .medium)).opacity(0.65)
                        }
                    }
                }
                .buttonStyle(FeedbackCommitButtonStyle())
                .disabled(controller.isSaving || (controller.hasLessons && !controller.storageReady))
                .help(controller.hasLessons ? "Save every lesson in this review and close" : "Close feedback")
            }
            if let app = controller.contextAppName, !app.isEmpty {
                Text(app).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 18)
    }
}

enum FeedbackInk {
    static let added = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.65, green: 0.87, blue: 0.73, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.34, blue: 0.25, alpha: 1)
    }
    static let addedBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.19, green: 0.34, blue: 0.25, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.93, blue: 0.85, alpha: 1)
    }
    static let removed = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.87, green: 0.69, blue: 0.60, alpha: 1)
            : NSColor(srgbRed: 0.47, green: 0.29, blue: 0.22, alpha: 1)
    }
}

private struct FeedbackReadingSurface: ViewModifier {
    var island = false
    var embedded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else if island {
            content.background(scheme == .dark ? Color(white: 0.065) : Color.white, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.09), lineWidth: 0.5))
        } else if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0.09), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(.thickMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.09), lineWidth: 0.5))
        }
    }
}

private struct FeedbackIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .frame(width: size, height: size)
            .background(.primary.opacity(configuration.isPressed ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8)).opacity(isEnabled ? 1 : 0.3)
    }
}

private struct FeedbackCommitButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 16).frame(height: 36)
            .background(scheme == .dark ? Color.white : Color(white: 0.12), in: RoundedRectangle(cornerRadius: 11))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
    }
}

private struct FeedbackReviewHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FeedbackExplanationHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
