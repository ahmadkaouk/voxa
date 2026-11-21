import AppKit
import AVFoundation
import SwiftUI

private typealias FeedbackViewState<Value> = SwiftUI.State<Value>
private typealias FeedbackViewStateObject<Value: ObservableObject> = SwiftUI.StateObject<Value>

/// English-only review, built to be read at a glance: the top fixes as
/// "You said → Better" pairs beside the whole dictation said more naturally.
struct FeedbackReviewView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 680
    var island = false
    var embeddedInIsland = false
    var onSizeChange: (() -> Void)? = nil
    var onMove: ((CGPoint, CGPoint, Bool) -> Void)? = nil
    /// A review with only fixes, or only a natural version, needs one column.
    static let width: CGFloat = 460
    /// Fixes on the left, the natural version on the right.
    static let wideWidth: CGFloat = 840
    static let fixesWidth: CGFloat = 440
    /// Fixes shown before "smaller fixes"; the model ranks the most important first.
    static let topFixes = 4

    @MainActor static func isSideBySide(_ controller: FeedbackController) -> Bool {
        !controller.fixes.isEmpty && controller.hasNaturalChanges
    }

    @MainActor static func width(for controller: FeedbackController) -> CGFloat {
        isSideBySide(controller) ? wideWidth : width
    }

    @FeedbackViewState private var expanded: UUID?
    @FeedbackViewState private var hoveredFix: UUID?
    @FeedbackViewState private var showsSmallerFixes = false
    @FeedbackViewStateObject private var speech = FeedbackSpeech()

    private var fixes: [SavedCorrection] { controller.fixes }
    private var visibleFixes: [SavedCorrection] { showsSmallerFixes ? fixes : Array(fixes.prefix(Self.topFixes)) }
    private var smallerFixCount: Int { max(0, fixes.count - Self.topFixes) }
    private var error: String? { controller.storageError ?? controller.progress.error }
    private var naturalText: String { controller.natural.map(\.natural).filter { !$0.isEmpty }.joined(separator: " ") }
    private var sideBySide: Bool { Self.isSideBySide(controller) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ViewThatFits(in: .vertical) {
                // Measure the whole review before introducing a scroll viewport.
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView(showsIndicators: false) { content }
            }
            .frame(maxHeight: max(120, maximumHeight - 124))
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: Self.width(for: controller))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in onSizeChange?() }
        .modifier(FeedbackReadingSurface(island: island, embedded: embeddedInIsland))
        .environment(\.controlActiveState, .active)
        .tint(Color(nsColor: FeedbackInk.added))
        .onChange(of: controller.findings.first?.id) { _ in
            expanded = nil; hoveredFix = nil; showsSmallerFixes = false; speech.stop()
        }
        .onDisappear { speech.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let repeated = repeatedSummary {
                    Text(repeated).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .modifier(IslandMoveHandle(onMove: onMove))
            .help(onMove == nil ? "English feedback" : "Drag to move Voxa")
            Button { controller.discardReview() } label: { Image(systemName: "xmark") }
                .buttonStyle(FeedbackIconButtonStyle(size: 26)).disabled(controller.isSaving)
                .accessibilityLabel("Close feedback").help("Close · \(controller.cancelHotkey.symbolLabel)")
        }
        .padding(.leading, 22).padding(.trailing, 16).padding(.top, 16).padding(.bottom, 6)
    }

    private var title: String {
        let shown = min(fixes.count, Self.topFixes)
        switch shown {
        case 0: return "Nothing to fix"
        case 1: return "1 thing to fix"
        default: return "\(shown) things to fix"
        }
    }

    private var repeatedSummary: String? {
        // Matches the repeat badges on the fixes counted in the title.
        let shown = min(fixes.count, Self.topFixes)
        let repeated = fixes.prefix(Self.topFixes).filter { previousOccurrences($0.feedback) > 0 }.count
        guard repeated > 0 else { return nil }
        if repeated == shown { return shown == 1 ? "made before" : shown == 2 ? "both made before" : "all made before" }
        return "\(repeated) you’ve made before"
    }

    @ViewBuilder private var content: some View {
        if sideBySide {
            // Opening a fix grows only the left column; the natural version stays in view.
            HStack(alignment: .top, spacing: 6) {
                fixesColumn.frame(width: Self.fixesWidth, alignment: .leading)
                naturalBox.frame(maxHeight: .infinity, alignment: .top)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 2)
            }
            .padding(.trailing, 16).padding(.bottom, 14)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                fixesColumn
                if controller.hasNaturalChanges {
                    naturalBox
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16).padding(.top, 10)
                } else if fixes.isEmpty {
                    Text("No mistakes this time.").font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.horizontal, 22).padding(.vertical, 8)
                }
            }
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fixesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error { recovery(error).padding(.horizontal, 16).padding(.vertical, 8) }
            if !fixes.isEmpty { fixesList }
            misheardNote
        }
    }

    // MARK: Fixes

    private var fixesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("You said").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 14, height: 1)
                Text("Better").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 14, height: 1)
            }
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.7).textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 2)
            .accessibilityHidden(true)
            ForEach(Array(visibleFixes.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 22) }
                fixRow(item)
            }
            if smallerFixCount > 0 {
                Button { showsSmallerFixes.toggle() } label: {
                    Text(showsSmallerFixes ? "Hide smaller fixes" : "+ \(smallerFixCount) smaller \(smallerFixCount == 1 ? "fix" : "fixes")")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 22).padding(.top, 2)
            }
        }
    }

    private func fixRow(_ item: SavedCorrection) -> some View {
        let feedback = item.feedback
        let pair = FeedbackPairText(said: feedback.original, better: feedback.suggestion)
        let open = expanded == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button { expanded = open ? nil : item.id } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pair.saidText).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary).frame(width: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pair.betterText(size: 15))
                        if let again = againLabel(feedback) { repeatBadge(again) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(open ? .secondary : .tertiary).frame(width: 14)
                }
                .font(.system(size: 15)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(.primary.opacity(hoveredFix == item.id ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(InactiveHover { inside in
                if inside { hoveredFix = item.id } else if hoveredFix == item.id { hoveredFix = nil }
            })
            .accessibilityLabel("You said: \(feedback.original). Better: \(feedback.suggestion)")
            .accessibilityValue(againLabel(feedback).map { "Made before, \($0)" } ?? "")
            .accessibilityHint(open ? "Hides the reason" : "Shows the reason and other ways to say it")
            if open {
                FeedbackFixDetail(feedback: feedback).padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 10)
    }

    /// A mistake made in earlier sessions, marked on the fix instead of in a section of its own.
    private func repeatBadge(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise").font(.system(size: 8.5, weight: .bold))
            Text(label).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(Color(nsColor: FeedbackInk.again))
        .padding(.leading, 5).padding(.trailing, 7).padding(.vertical, 2)
        .background(Color(nsColor: FeedbackInk.again).opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("You’ve made this kind of mistake before")
    }

    private func previousOccurrences(_ feedback: EnglishFeedback) -> Int {
        feedback.focus.map { controller.previousOccurrences(of: $0) } ?? 0
    }

    private static let ordinal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private func againLabel(_ feedback: EnglishFeedback) -> String? {
        let previous = previousOccurrences(feedback)
        guard previous > 0, let count = Self.ordinal.string(from: NSNumber(value: previous + 1)) else { return nil }
        return "\(count) time"
    }

    @ViewBuilder private var misheardNote: some View {
        let heard = controller.transcriptionIssues.map { "“\($0.feedback.original)”" }
        if !heard.isEmpty {
            Text(heard.count == 1 ? "Not counted: \(heard[0]) was probably misheard."
                                  : "Not counted, probably misheard: \(heard.joined(separator: ", ")).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 2)
        }
    }

    // MARK: Natural version

    private var naturalBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Said more naturally").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .help("Rewritten from scratch where needed · same ideas, same order")
                Spacer(minLength: 8)
                compareSwitch
                Button { speech.toggle(naturalText) } label: {
                    Image(systemName: speech.isSpeaking ? "stop.fill" : "speaker.wave.2")
                }
                .buttonStyle(FeedbackIconButtonStyle(size: 28))
                .accessibilityLabel(speech.isSpeaking ? "Stop reading" : "Listen to the natural version")
                .help(speech.isSpeaking ? "Stop" : "Listen")
            }
            if controller.showsComparison { comparison }
            else {
                Text(naturalText).font(.system(size: 16)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Clean shows only the natural version; Compare puts each spoken sentence above it.
    private var compareSwitch: some View {
        HStack(spacing: 0) {
            compareSegment("Clean", selected: !controller.showsComparison, shortcut: nil,
                           label: "Show only the natural version")
            compareSegment("Compare", selected: controller.showsComparison,
                           shortcut: controller.compareHotkey.symbolLabel, label: "Compare with what you said")
        }
        .padding(2)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .help("Compare with what you said · \(controller.compareHotkey.symbolLabel)")
    }

    private func compareSegment(_ title: String, selected: Bool, shortcut: String?, label: String) -> some View {
        Button { if !selected { controller.toggleComparison() } } label: {
            HStack(spacing: 5) {
                Text(title)
                if let shortcut { Text(shortcut).opacity(0.7) }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(.primary.opacity(selected ? 0.13 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(controller.natural.enumerated()), id: \.offset) { _, pair in
                let unchanged = pair.natural == pair.said
                VStack(alignment: .leading, spacing: 3) {
                    if !unchanged {
                        Text(pair.said).strikethrough(true, color: Color(nsColor: FeedbackInk.wrong).opacity(0.55))
                            .font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    if !pair.natural.isEmpty {
                        Text(pair.natural).font(.system(size: 16, weight: unchanged ? .regular : .medium))
                            .foregroundColor(unchanged ? .primary : Color(nsColor: FeedbackInk.added))
                    }
                }
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(unchanged ? pair.natural : "You said: \(pair.said). More natural: \(pair.natural)")
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Footer and recovery

    /// Says what the button does, so saving is never a surprise.
    private var saveSummary: String? {
        guard controller.hasLessons else { return nil }
        switch fixes.count {
        case 1: return "Saves this fix to your lessons"
        case 2: return "Saves both fixes to your lessons"
        default: return "Saves all \(fixes.count) fixes to your lessons"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let saveSummary {
                Text(saveSummary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { controller.saveAndClose() } label: {
                HStack(spacing: 9) {
                    if controller.isSaving { ProgressView().controlSize(.mini) }
                    Text(controller.isSaving ? (controller.storageReady ? "Saving…" : "Loading…") : "Got it")
                    if !controller.isSaving {
                        Text(controller.saveHotkey.symbolLabel).font(.system(size: 11, weight: .medium)).opacity(0.65)
                    }
                }
            }
            .buttonStyle(FeedbackCommitButtonStyle())
            .disabled(controller.isSaving || (controller.hasLessons && !controller.storageReady))
            .help(controller.hasLessons ? "Save these fixes to your lessons and close" : "Close feedback")
        }
        .padding(.leading, 22).padding(.trailing, 16).padding(.top, 12).padding(.bottom, 14)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
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
}

extension FeedbackPairText {
    /// What was said: context in grey, the wrong words struck through in red.
    var saidText: AttributedString {
        said.reduce(into: AttributedString()) { text, run in
            var part = AttributedString(run.text)
            if run.changed {
                part.foregroundColor = Color(nsColor: FeedbackInk.wrong)
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Color(nsColor: FeedbackInk.wrong))
            } else {
                part.foregroundColor = .secondary
            }
            text += part
        }
    }

    /// The better wording, with the changed words in bold green.
    func betterText(size: CGFloat) -> AttributedString {
        better.reduce(into: AttributedString()) { text, run in
            var part = AttributedString(run.text)
            if run.changed {
                part.foregroundColor = Color(nsColor: FeedbackInk.added)
                part.backgroundColor = Color(nsColor: FeedbackInk.addedBackground)
                part.font = .system(size: size, weight: .semibold)
            }
            text += part
        }
    }
}

/// Why a fix is better, and other ways to say it, shown when a fix is opened.
struct FeedbackFixDetail: View {
    let feedback: EnglishFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(feedback.explanation).font(.system(size: 13)).lineSpacing(2)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.bottom, feedback.alternatives.isEmpty ? 0 : 9)
            ForEach(feedback.alternatives, id: \.wording) { alternative in
                Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(alternative.wording).font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(alternative.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 150, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, feedback.alternatives.isEmpty ? 12 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reads the natural version aloud with the Mac's built-in voice; nothing leaves the Mac.
@MainActor
final class FeedbackSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if isSpeaking { stop(); return }
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
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
    /// The words that were wrong, struck through next to the better wording.
    static let wrong = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.55, blue: 0.5, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.15, blue: 0.12, alpha: 1)
    }
    /// Marks a mistake the speaker has made in earlier sessions.
    static let again = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.73, blue: 0.44, alpha: 1)
            : NSColor(srgbRed: 0.63, green: 0.30, blue: 0.0, alpha: 1)
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
            .padding(.horizontal, 16).frame(height: 34)
            .background(scheme == .dark ? Color.white : Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
    }
}
