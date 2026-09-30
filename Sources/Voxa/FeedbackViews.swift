import AppKit
import SwiftUI

// Disambiguate the macOS 13 property wrapper from the newer SDK's State macro.
private typealias FeedbackViewState<Value> = SwiftUI.State<Value>

private enum FeedbackPalette {
    static let removed = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.55, blue: 0.59, alpha: 1)
            : NSColor(red: 0.68, green: 0.18, blue: 0.23, alpha: 1)
    })
    static let added = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.40, green: 0.85, blue: 0.62, alpha: 1)
            : NSColor(red: 0.12, green: 0.44, blue: 0.28, alpha: 1)
    })
    static let accent = Color(nsColor: .systemTeal)
}

struct FeedbackLessonView: View {
    let feedback: EnglishFeedback

    var body: some View {
        let difference = FeedbackDifference(original: feedback.original, suggestion: feedback.suggestion)
        VStack(alignment: .leading, spacing: 12) {
            phrase(difference.original, title: "Original", added: false)
            if feedback.kind == .phrasing {
                alternative(feedback.suggestion, explanation: feedback.explanation)
            } else {
                phrase(difference.suggestion,
                       title: feedback.kind == .transcriptionIssue ? "Possible wording · Check transcription" : "Corrected",
                       added: true)
                Text(feedback.explanation)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let option = feedback.alternative {
                    alternative(option.wording, explanation: option.explanation)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alternative(_ wording: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Another way to say it · Optional")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(wording).font(.system(size: 15)).foregroundStyle(.primary).lineSpacing(3)
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func phrase(_ tokens: [FeedbackDifference.Token], title: String, added: Bool) -> some View {
        let isCorrection = feedback.kind != .phrasing
        let color = added ? FeedbackPalette.added : FeedbackPalette.removed
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            tokens.reduce(Text("")) { result, token in
                let fragment = Text(token.text)
                return result + (token.changed && isCorrection
                    ? fragment.foregroundColor(color).bold().strikethrough(!added).underline(added)
                    : fragment.foregroundColor(.primary))
            }
            .font(.system(size: 16)).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(title): \(tokens.map(\.text).joined())")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeedbackActionStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.24 : 0.12),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.35)))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct FeedbackReviewView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 620
    static let width: CGFloat = 480

    private var listHeight: CGFloat {
        min(controller.findings.count > 1 ? 440 : 260, max(120, maximumHeight - 160))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text("English feedback")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(controller.findings.count) \(controller.findings.count == 1 ? "suggestion" : "suggestions")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss this English review")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(orderedFindings.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        FeedbackLessonView(feedback: item.feedback).padding(.vertical, 14).padding(.trailing, 5)
                    }
                }
            }
            .frame(height: listHeight)
            .id(controller.findings.first?.id) // Every new review starts with its original text visible.
            Divider()
            if !controller.findings.isEmpty {
                HStack(spacing: 10) {
                    Button { controller.saveAndClose() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(controller.hasLessons ? "Accept & save all" : "Done")
                            keycap(FeedbackShortcut.saveLabel)
                        }
                    }
                    .buttonStyle(FeedbackActionStyle(color: FeedbackPalette.added))
                    .disabled(controller.isSaving || (controller.hasLessons && !controller.storageReady))
                    .help("Save all lessons in this review and close it. Possible transcription issues are not saved. Inserted text is unchanged.")
                    Button { controller.discardReview() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Discard all")
                            keycap(FeedbackShortcut.discardLabel)
                        }
                    }
                    .buttonStyle(FeedbackActionStyle(color: FeedbackPalette.removed))
                    .disabled(controller.isSaving)
                    .help("Close this entire review without saving it. Previously saved lessons stay unchanged.")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.storageError ?? "Accept saves all lessons. Your inserted text stays unchanged.")
                    .font(.system(size: 10))
                    .foregroundStyle(controller.storageError == nil ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.findings.contains(where: { $0.feedback.kind == .transcriptionIssue }) {
                    Text("Possible transcription issues are not saved as lessons.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !controller.storageReady, !controller.isSaving {
                    Button("Retry saved lessons") { controller.reloadSaved() }.font(.caption)
                }
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.1)))
    }

    private var orderedFindings: [SavedCorrection] {
        controller.findings.filter { $0.feedback.kind != .phrasing }
            + controller.findings.filter { $0.feedback.kind == .phrasing }
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
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
                    Text("Choose Accept & save on a correction.\nThen come here to try it in a new sentence.")
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
