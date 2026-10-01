import AppKit
import SwiftUI

private typealias PracticeViewState<Value> = SwiftUI.State<Value>

struct PracticeView: View {
    @ObservedObject var controller: PracticeController
    @PracticeViewState private var typing = false
    @PracticeViewState private var draft = ""
    @PracticeViewState private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.isReview ? "A short review" : "Make it yours")
                        .font(.system(size: 23, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { controller.close() }.keyboardShortcut(.cancelAction)
            }
            if let error = controller.history.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { controller.history.retry() }.disabled(controller.history.isSaving)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if controller.phase == .complete {
                        completion
                    } else if let target = controller.target {
                        exercise(target)
                        if !controller.answer.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Your answer").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Text(controller.answer).font(.system(size: 15)).textSelection(.enabled)
                            }
                        }
                        if let result = controller.result {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(result.outcome == .success ? "Pattern used well" : "One more try",
                                      systemImage: result.outcome == .success ? "checkmark.circle" : "arrow.counterclockwise")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(result.outcome == .success ? FeedbackPalette.added : .primary)
                                Text(result.explanation).font(.system(size: 13)).foregroundStyle(.secondary)
                                if let suggestion = result.suggestion {
                                    Text(suggestion).font(.system(size: 16, weight: .medium))
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let error = controller.error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if controller.phase == .ready || controller.phase == .failed {
                            if typing {
                                TextEditor(text: $draft).font(.system(size: 15)).padding(8).frame(height: 100)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15)))
                                    .accessibilityLabel("Your practice sentence")
                                    .onChange(of: draft) { value in
                                        if value.count > 4_000 { draft = String(value.prefix(4_000)) }
                                    }
                                HStack {
                                    Button("Check sentence") { controller.submitTyped(draft) }
                                        .buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
                                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button("Speak instead") { typing = false; draft = "" }.buttonStyle(.link)
                                }
                            } else {
                                HStack(spacing: 14) {
                                    Button { controller.record() } label: { Label("Record answer", systemImage: "mic") }
                                        .buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
                                    Button("Type instead") { typing = true }.buttonStyle(.link)
                                }
                            }
                        }
                        if controller.isBusy { recordingStatus }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }
            Divider()
            HStack {
                if controller.phase == .result {
                    Button("Try again") { controller.retryAttempt(); draft = "" }
                    Spacer()
                    if controller.step == .repeatSentence {
                        Button("Try a new sentence") { controller.newSentence(); draft = ""; reveal = false }
                            .buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
                    } else {
                        Button(controller.isReview ? "Next" : "Done") {
                            if controller.isReview { controller.next() } else { controller.close() }
                        }.buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
                    }
                } else if controller.canAnswer {
                    if controller.step == .repeatSentence {
                        Button("Skip to a new sentence") { controller.newSentence(); draft = ""; reveal = false }
                            .buttonStyle(.link)
                    } else if controller.isReview {
                        Button("Skip this one") { controller.next() }.buttonStyle(.link)
                    }
                    Spacer()
                } else { Spacer() }
            }
            Text("Your answer is checked with your configured AI service. Audio and answers aren’t saved on this Mac or pasted into your work. Practice doesn’t change your level estimate.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
        }
        .padding(28).frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 590)
        .onChange(of: controller.index) { _ in typing = false; draft = ""; reveal = false }
        .onChange(of: controller.isPresented) { _ in typing = false; draft = ""; reveal = false }
    }

    private var subtitle: String {
        if controller.phase == .complete { return "A little practice, whenever it suits you." }
        if controller.isReview { return "\(controller.index + 1) of \(controller.targets.count) · Use a saved pattern in a new sentence" }
        return controller.step == .repeatSentence ? "1 · Say the improved version" : "2 · Use the pattern with a new idea"
    }

    private func exercise(_ target: PracticeTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let focus = target.focus {
                Text(focus.label).font(.system(size: 11, weight: .medium)).foregroundStyle(FeedbackPalette.accent)
            }
            if controller.step == .repeatSentence {
                Text(target.wording).font(.system(size: 22, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(target.explanation).font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Say this once, then try the pattern in your own sentence.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(target.prompt).font(.system(size: 21, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Button(reveal ? "Hide example" : "Show example") { reveal.toggle() }.buttonStyle(.link)
                if reveal {
                    Text(target.wording).font(.system(size: 16, weight: .medium))
                    Text(target.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 12) {
            if controller.phase == .recording {
                Image(systemName: "mic.fill").foregroundStyle(FeedbackPalette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Listening · \(controller.seconds)s / 40s").font(.system(size: 13, weight: .medium))
                    ProgressView(value: min(1, max(0, controller.level))).frame(width: 130)
                        .accessibilityLabel("Microphone level")
                }
                Spacer()
                Button("Stop & check") { controller.stop() }.buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
            } else {
                ProgressView().controlSize(.small)
                Text(controller.phase == .starting ? "Preparing microphone…" :
                        controller.phase == .finishing ? "Finishing recording…" :
                        controller.phase == .transcribing ? "Transcribing your answer…" : "Checking this pattern…")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(FeedbackPalette.accent)
            Text(controller.targets.isEmpty ? "Nothing due right now." : "That’s your short review.")
                .font(.system(size: 22, weight: .medium))
            Text(controller.targets.isEmpty ? "Save lessons from your dictations to revisit them here. Reviewed patterns return after a little time has passed." :
                    "Your reviewed patterns will return later. You can get back to work whenever you’re ready.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Back to work") { controller.close() }.buttonStyle(.borderedProminent).tint(FeedbackPalette.accent)
        }.padding(.vertical, 30)
    }
}

@MainActor
final class PracticeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var controller: PracticeController?

    func show(_ controller: PracticeController) {
        self.controller = controller
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 590),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            window.title = "English Practice"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 480, height: 520)
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: PracticeView(controller: controller))
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func hide() { window?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { controller?.close() }
}
