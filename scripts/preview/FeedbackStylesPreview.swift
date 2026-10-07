import AppKit
import SwiftUI

// A self-contained design study: synthetic text, no accounts, recording, or saved lessons.
private typealias DesignState<Value> = SwiftUI.State<Value>

private enum FeedbackStyle: Int, CaseIterable, Identifiable {
    case quiet = 1, reading, focused
    var id: Self { self }
    var title: String {
        switch self {
        case .quiet: return "Quiet card"
        case .reading: return "Reading panel"
        case .focused: return "One at a time"
        }
    }
    var detail: String {
        switch self {
        case .quiet: return "A quick before-and-after. Details when you need them."
        case .reading: return "The improved sentence first, with room to learn."
        case .focused: return "One correction in focus. Move through at your own pace."
        }
    }
}

private enum Backdrop: String, CaseIterable, Identifiable {
    case wallpaper = "Wallpaper", light = "Light app", dark = "Dark app"
    var id: Self { self }
    var scheme: ColorScheme { self == .light ? .light : .dark }
}

private enum Sample: String, CaseIterable, Identifiable {
    case corrections = "Two corrections", long = "Long sentence", alternative = "Optional wording"
    var id: Self { self }
    var original: String {
        switch self {
        case .corrections: return "Yesterday I go over the proposal with Maya. She explain the next steps."
        case .long: return "The list of applications that I use for recording meetings, organising my notes and reviewing my English practice are available on this computer whenever I need to prepare for a conversation with my team."
        case .alternative: return "I want to ask you if it is possible for us to move the meeting to tomorrow."
        }
    }
    var corrected: String {
        switch self {
        case .corrections: return "Yesterday I went over the proposal with Maya. She explained the next steps."
        case .long: return original.replacingOccurrences(of: "are available", with: "is available")
        case .alternative: return "Could we move the meeting to tomorrow?"
        }
    }
    var changes: [String] {
        switch self {
        case .corrections: return ["went", "explained"]
        case .long: return ["is available"]
        case .alternative: return ["Could we"]
        }
    }
    var summary: String { self == .alternative ? "One optional alternative" : self == .long ? "One grammar fix" : "Two grammar fixes" }
    var rule: String {
        switch self {
        case .corrections: return "Yesterday + past-tense verb"
        case .long: return "The list of + plural noun + is…"
        case .alternative: return "Could we + action?"
        }
    }
    var explanation: String {
        switch self {
        case .corrections: return "Yesterday places both actions in the past. Use went and explained."
        case .long: return "The subject is the singular noun list. The phrase about applications describes the list, so the verb is singular too."
        case .alternative: return "Your original sentence is correct. This is a shorter way to make the same polite request."
        }
    }
}

@MainActor
private final class GalleryModel: ObservableObject {
    @Published var backdrop: Backdrop = .wallpaper
    @Published var sample: Sample = .corrections
    @Published var floating: FeedbackStyle?
    private var panel: NSPanel?

    func float(_ style: FeedbackStyle) {
        hide()
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 428, height: 608),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = TransparentDesignHost(rootView:
            ScrollView {
                FeedbackConcept(style: style, sample: sample).padding(24)
            }.frame(width: 428, height: 608)
                .contextMenu { Button("Hide preview") { self.hide() } })
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(.init(x: frame.maxX - 450, y: frame.minY + 30))
        }
        self.panel = panel
        floating = style
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil); panel = nil; floating = nil }
}

private final class TransparentDesignHost<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct FeedbackConcept: View {
    let style: FeedbackStyle
    let sample: Sample
    @DesignState private var expanded = false
    @DesignState private var pinned = false
    @DesignState private var page = 0
    @DesignState private var saved = false
    @DesignState private var closed = false
    @DesignState private var practising = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }
    private var hasPages: Bool { sample == .corrections }
    private var focusedOriginal: String {
        hasPages ? (page == 0 ? "Yesterday I go over the proposal with Maya." : "She explain the next steps.") : sample.original
    }
    private var focusedCorrected: String {
        hasPages ? (page == 0 ? "Yesterday I went over the proposal with Maya." : "She explained the next steps.") : sample.corrected
    }

    var body: some View {
        Group {
            if saved || closed { finished }
            else {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if style == .quiet { quietContent }
                    else if style == .reading { readingContent }
                    else { focusedContent }
                    Divider().opacity(0.5)
                    footer
                }
                .padding(20)
            }
        }
        .frame(width: 380)
        .modifier(ConceptSurface(opaque: reduceTransparency, shape: shape))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 7)
        .popover(isPresented: $practising) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Try it once", systemImage: "mic").font(.headline)
                Text(sample == .alternative ? "Make a polite request using ‘Could we…?’" : sample == .long ? "Describe a list you use at work." : "Describe one thing you did yesterday.")
                    .frame(width: 240, alignment: .leading)
                Text("Design preview · microphone is off").font(.caption).foregroundStyle(.secondary)
                Button("Done") { practising = false }
            }.padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if style == .reading {
                Image(systemName: "text.bubble").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemBlue))
                    .frame(width: 34, height: 34)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("English feedback").font(.system(size: 15, weight: .semibold))
                Text(style == .focused ? "\(page + 1) of \(hasPages ? 2 : 1) · \(sample == .alternative ? "Optional" : "Grammar")" : sample.summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { pinned.toggle() } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12)).frame(width: 26, height: 26)
            }.buttonStyle(.plain).foregroundStyle(pinned ? Color(nsColor: .systemBlue) : Color.secondary)
                .help(pinned ? "Unpin feedback" : "Keep feedback open")
                .accessibilityLabel(pinned ? "Unpin feedback" : "Keep feedback open")
            Button { closed = true } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26).background(.primary.opacity(0.065), in: Circle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close feedback")
        }
    }

    private var quietContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().opacity(0.5)
            sentence(label: "YOU SAID", value: sample.original, highlighted: false, size: 14)
            sentence(label: sample == .alternative ? "YOU COULD SAY" : "IMPROVED", value: sample.corrected, highlighted: true, size: 16)
            Button { expanded.toggle() } label: {
                HStack {
                    Text(expanded ? "Hide explanation" : "Why this change?")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.font(.system(size: 12, weight: .medium)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color(nsColor: .systemBlue))
            if expanded { explanation }
        }
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(sample == .alternative ? "Another way to say it" : "A little clearer", systemImage: sample == .alternative ? "arrow.left.arrow.right" : "checkmark.circle")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                highlighted(sample.corrected).font(.system(size: 17, weight: .medium)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            DisclosureGroup("Your original sentence", isExpanded: $expanded) {
                Text(sample.original).font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.system(size: 12)).tint(.secondary)
            explanation
        }
    }

    private var focusedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 5) {
                ForEach(0..<(hasPages ? 2 : 1), id: \.self) { index in
                    Capsule().fill(index == page ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.10))
                        .frame(height: 3)
                }
            }.accessibilityLabel("Correction \(page + 1) of \(hasPages ? 2 : 1)")
            Text(sample == .corrections ? "Keep it in the past" : sample == .long ? "Match the subject" : "Make it concise")
                .font(.system(size: 21, weight: .semibold))
            sentence(label: "BEFORE", value: focusedOriginal, highlighted: false, size: 14)
            sentence(label: sample == .alternative ? "ALTERNATIVE" : "AFTER", value: focusedCorrected, highlighted: true, size: 17)
            VStack(alignment: .leading, spacing: 8) {
                Text(sample.rule).font(.system(size: 12, weight: .medium))
                Text(sample == .corrections ? (page == 0 ? "Use went for a completed action yesterday." : "Keep the second action in the past: explained.") : sample.explanation)
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.74)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if hasPages {
                HStack {
                    Button { page = 0 } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(page == 0)
                    Spacer()
                    Button { page = 1 } label: { Label("Next correction", systemImage: "chevron.right") }
                        .disabled(page == 1)
                }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemBlue))
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REMEMBER").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
            Text(sample.rule).font(.system(size: 13, weight: .medium))
            Text(sample.explanation).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.74)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if style == .quiet {
                Text(pinned ? "Pinned" : "Timer pauses while reading")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button { practising = true } label: { Label("Try once", systemImage: "mic") }
                    .buttonStyle(.glass).controlSize(.small)
            }
            Spacer(minLength: 2)
            Button { saved = true } label: {
                Text(style == .focused && hasPages ? "Save both" : "Save")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 5)
            }.buttonStyle(.glassProminent).tint(Color(nsColor: .systemBlue)).controlSize(.regular)
                .help("Simulate saving these lessons")
        }
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: saved ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 32)).foregroundStyle(saved ? Color(nsColor: .systemGreen) : .secondary)
            Text(saved ? "Saved for practice" : "Feedback closed").font(.headline)
            Text("Preview only · no lessons are saved").font(.caption).foregroundStyle(.secondary)
            Button("Replay preview") { saved = false; closed = false; page = 0 }
                .buttonStyle(.glass)
        }.padding(30).frame(maxWidth: .infinity)
    }

    private func sentence(label: String, value: String, highlighted isHighlighted: Bool, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Group {
                if isHighlighted { highlighted(value) }
                else { Text(value).foregroundStyle(.primary.opacity(0.72)) }
            }.font(.system(size: size)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlighted(_ value: String) -> Text {
        var text = AttributedString(value)
        for change in sample.changes {
            if let range = text.range(of: change) {
                text[range].foregroundColor = .primary
                text[range].backgroundColor = Color(nsColor: .systemBlue).opacity(0.20)
                text[range].font = .system(size: style == .quiet ? 16 : 17, weight: .semibold)
            }
        }
        return Text(text)
    }
}

private struct ConceptSurface: ViewModifier {
    let opaque: Bool
    let shape: RoundedRectangle
    @ViewBuilder func body(content: Content) -> some View {
        if opaque { content.background(Color(nsColor: .windowBackgroundColor), in: shape) }
        else { content.glassEffect(.clear, in: shape) }
    }
}

private struct SceneBackdrop: View {
    let backdrop: Backdrop
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if backdrop == .wallpaper {
                    Color(red: 0.10, green: 0.15, blue: 0.25)
                    Ellipse().fill(Color(red: 0.18, green: 0.45, blue: 0.66))
                        .frame(width: 430, height: 270).blur(radius: 45).rotationEffect(.degrees(-35)).offset(x: -130, y: -130)
                    Ellipse().fill(Color(red: 0.44, green: 0.29, blue: 0.58))
                        .frame(width: 300, height: 360).blur(radius: 45).offset(x: 150, y: 170)
                } else {
                    (backdrop == .light ? Color(white: 0.92) : Color(white: 0.10))
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(0..<16) { index in
                            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.06))
                                .frame(width: geometry.size.width - CGFloat(45 + index % 3 * 26), height: 5)
                        }
                    }.padding(20)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
    }
}

private struct FeedbackGallery: View {
    @ObservedObject var model: GalleryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VOXA / FEEDBACK STUDY").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Text("Feedback, in glass.").font(.system(size: 28, weight: .semibold))
                    Text("Three ways to read, understand, and keep a correction.").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    Picker("Background", selection: $model.backdrop) {
                        ForEach(Backdrop.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    Picker("Example", selection: $model.sample) {
                        ForEach(Sample.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 280)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(FeedbackStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("\(style.rawValue)").font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22).background(.primary.opacity(0.07), in: Circle())
                            Text(style.title).font(.system(size: 16, weight: .semibold))
                        }
                        ZStack(alignment: .top) {
                            SceneBackdrop(backdrop: model.backdrop)
                            ScrollView {
                                FeedbackConcept(style: style, sample: model.sample).id(model.sample)
                                    .padding(.vertical, 22).frame(maxWidth: .infinity)
                            }.scrollIndicators(.hidden)
                        }
                        .environment(\.colorScheme, model.backdrop.scheme)
                        .frame(width: 412, height: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text(style.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(height: 32, alignment: .top).fixedSize(horizontal: false, vertical: true)
                        Button { model.float(style) } label: { Label("Float on desktop", systemImage: "arrow.up.forward.square") }
                            .controlSize(.small)
                    }.frame(width: 412, alignment: .leading)
                }
            }
            HStack {
                Text("Actual size · Native Liquid Glass · Sample text only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.floating != nil { Button("Hide floating preview", action: model.hide).controlSize(.small) }
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand { model.hide() }
            .onChange(of: model.sample) { if let style = model.floating { model.float(style) } }
            .onDisappear { model.hide() }
    }
}

@main
private struct FeedbackStylesPreview: App {
    @StateObject private var model = GalleryModel()
    var body: some Scene {
        Window("Voxa · Feedback in Glass", id: "feedback-gallery") { FeedbackGallery(model: model) }
            .windowResizability(.contentSize)
            .commands {
                CommandMenu("Preview") {
                    ForEach(FeedbackStyle.allCases) { style in
                        Button("Float \(style.title)") { model.float(style) }
                            .keyboardShortcut(KeyEquivalent(Character(String(style.rawValue))), modifiers: .command)
                    }
                    Divider()
                    Button("Hide floating preview", action: model.hide).keyboardShortcut(.escape, modifiers: [])
                }
            }
    }
}
