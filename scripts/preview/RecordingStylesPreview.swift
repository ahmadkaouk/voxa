import AppKit
import Combine
import SwiftUI

// A design study only: no capture, hotkeys, sounds, credentials, or app preferences.
// The waveform uses the shipping bar's envelope with a simulated input level.
private enum RecordingStyle: Int, CaseIterable, Identifiable {
    case clear = 1, frosted, split, compact, combined
    static let originals: [Self] = [.clear, .frosted, .split, .compact]
    var id: Self { self }
    var name: String {
        switch self {
        case .clear: return "Clear capsule"
        case .frosted: return "Frosted studio"
        case .split: return "Split glass"
        case .compact: return "Compact pebble"
        case .combined: return "Compact native"
        }
    }
    var detail: String {
        switch self {
        case .clear: return "Airy and transparent. Closest to your current layout."
        case .frosted: return "A softer surface, with a clear recording status."
        case .split: return "One pill for your voice. A separate stop button."
        case .compact: return "Smoked glass with a smaller footprint."
        case .combined: return "Adaptive glass and standard macOS status colors."
        }
    }
    var size: CGSize {
        switch self {
        case .clear: return .init(width: 280, height: 52)
        case .frosted: return .init(width: 300, height: 64)
        case .split: return .init(width: 288, height: 52)
        case .compact: return .init(width: 214, height: 44)
        case .combined: return .init(width: 220, height: 48)
        }
    }
    var dimensions: String { "\(Int(size.width)) × \(Int(size.height)) pt" }
}

private enum PreviewPhase: String, CaseIterable, Identifiable {
    case listening = "Listening", processing = "Processing", complete = "Complete"
    var id: Self { self }
    var title: String {
        switch self {
        case .listening: return "Listening"
        case .processing: return "Transcribing"
        case .complete: return "Text ready"
        }
    }
}

private enum PreviewBackdrop: String, CaseIterable, Identifiable {
    case aurora = "Wallpaper", light = "Light app", dark = "Dark app"
    var id: Self { self }
    var scheme: ColorScheme { self == .light ? .light : .dark }
}

@MainActor
private final class GlassPreviewModel: ObservableObject {
    @Published var phase: PreviewPhase = .listening
    @Published var backdrop: PreviewBackdrop = .aurora
    @Published var animate = true
    @Published var floatingStyle: RecordingStyle?
    @Published var showOriginals = false
    private var transition: Task<Void, Never>?
    private var panel: NSPanel?
    private var closeObserver: AnyCancellable?

    func showPhase(_ next: PreviewPhase) {
        transition?.cancel()
        phase = next
    }

    func finish() {
        transition?.cancel()
        phase = .processing
        transition = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            self?.phase = .complete
        }
    }

    func replay() { showPhase(.listening) }

    func float(_ style: RecordingStyle) {
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 344, height: 104),
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
            self.panel = panel
            let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            panel.setFrameOrigin(.init(x: round(frame.midX - 172), y: frame.minY + 20))
        }
        floatingStyle = style
        panel.contentView = GlassHostingView(rootView: FloatingStyleView(style: style, model: self))
        panel.orderFrontRegardless()
    }

    func hideFloating() {
        panel?.orderOut(nil)
        floatingStyle = nil
    }

    func watchGalleryClose() {
        closeObserver = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
                self?.hideFloating()
            }
    }
}

private final class GlassHostingView<Content: View>: NSHostingView<Content> {
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

private struct FloatingStyleView: View {
    let style: RecordingStyle
    @ObservedObject var model: GlassPreviewModel
    var body: some View {
        RecordingGlassBar(style: style, phase: model.phase, animate: model.animate, onStop: model.finish)
            .padding(22)
            .frame(width: 344, height: 108)
            .help("\(style.name) preview · Drag to move")
            .contextMenu {
                Button("Replay recording", action: model.replay)
                Button("Hide preview", action: model.hideFloating)
            }
    }
}

private struct RecordingGlassBar: View {
    let style: RecordingStyle
    let phase: PreviewPhase
    let animate: Bool
    var onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var ink: Color {
        if style == .combined { return Color(nsColor: .labelColor) }
        return style == .compact || colorScheme == .dark ? .white : .black
    }

    var body: some View {
        Group {
            switch style {
            case .clear: clear
            case .frosted: frosted
            case .split: split
            case .compact: compact
            case .combined: nativeCompact
            }
        }
        .frame(width: style.size.width, height: style.size.height)
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.name), \(phase.title), simulated recording")
    }

    private var clear: some View {
        HStack(spacing: 16) {
            timer
            waveform(count: 21, width: 108)
            stop(size: 32)
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 52)
        .glassEffect(.clear, in: Capsule())
    }

    private var frosted: some View {
        HStack(spacing: 12) {
            Image(systemName: phase == .complete ? "checkmark" : "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(.primary.opacity(0.06), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(phase.title).font(.system(size: 12, weight: .semibold))
                Text("0:24").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }.frame(width: 78, alignment: .leading)
            waveform(count: 13, width: 67)
            Spacer(minLength: 0)
            stop(size: 34)
        }
        .padding(.horizontal, 14)
        .frame(width: 300, height: 64)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var split: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 14) {
                    Circle().fill(phase == .complete ? Color.green : Color.red)
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    timer
                    waveform(count: 19, width: 94)
                }
                .padding(.horizontal, 16)
                .frame(width: 226, height: 52)
                .glassEffect(.regular, in: Capsule())
                Button(action: onStop) {
                    Image(systemName: phase == .complete ? "checkmark" : "stop.fill")
                        .font(.system(size: phase == .complete ? 15 : 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(phase == .complete ? .green : .red).interactive(), in: Circle())
                .disabled(phase != .listening)
                .accessibilityLabel("Finish simulated dictation")
                .help("Preview the processing and completion states")
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 12) {
            Circle().fill(phase == .complete ? Color.green : Color.red)
                .frame(width: 5, height: 5).accessibilityHidden(true)
            timer
            waveform(count: 11, width: 54)
            stop(size: 28)
        }
        .padding(.horizontal, 13)
        .frame(width: 214, height: 44)
        .glassEffect(.regular.tint(.black.opacity(0.28)), in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    // The material and appearance stay system-controlled. Color communicates the
    // recording action and success; processing and completion are status, not buttons.
    private var nativeCompact: some View {
        Group {
            switch phase {
            case .listening:
                HStack(spacing: 16) {
                    timer
                    waveform(count: 17, width: 88)
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color(nsColor: .systemRed), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Finish simulated dictation")
                    .help("Finish dictation")
                }
                .padding(.horizontal, 16)
            case .processing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.callout.weight(.medium)).foregroundStyle(.primary)
                }.accessibilityElement(children: .ignore).accessibilityLabel("Transcribing")
            case .complete:
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("Text ready").font(.callout.weight(.medium)).foregroundStyle(.primary)
                }.accessibilityElement(children: .ignore).accessibilityLabel("Dictation complete, text ready")
            }
        }
        .frame(width: 220, height: 48)
        .glassEffect(.clear, in: ActivityOverlayMetrics.shape)
    }

    private var timer: some View {
        Text("0:24").font(.system(size: 12, weight: .medium)).monospacedDigit()
            .foregroundStyle(ink.opacity(style == .combined ? 1 : 0.78))
            .frame(width: 34, alignment: .leading)
            .accessibilityLabel("24 seconds")
    }

    @ViewBuilder private func waveform(count: Int, width: CGFloat) -> some View {
        Group {
            switch phase {
            case .listening:
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate || reduceMotion)) { timeline in
                    let t = animate && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 1.6
                    let level = animate && !reduceMotion ? 0.35 + pow((sin(t * 2.8) + 1) / 2, 2) * 0.6 : 0.8
                    HStack(spacing: 2) {
                        ForEach(0..<count, id: \.self) { i in
                            let index = i * (ActivityOverlayMetrics.waveform.count - 1) / max(1, count - 1)
                            Capsule().fill(ink.opacity(style == .combined ? 1 : 0.88))
                                .frame(width: 3, height: ActivityOverlayMetrics.barHeight(index: index, level: level, time: t))
                        }
                    }
                }.accessibilityLabel("Simulated microphone waveform")
            case .processing:
                ProgressView().controlSize(.small).accessibilityLabel("Transcribing")
            case .complete:
                Image(systemName: "checkmark").font(.system(size: 17, weight: .medium))
                    .accessibilityLabel("Text ready")
            }
        }.frame(width: width, height: 26)
    }

    private func stop(size: CGFloat) -> some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill").font(.system(size: 10, weight: .medium))
                .frame(width: size, height: size)
                .background(.primary.opacity(0.09), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(phase == .listening ? 1 : 0.25)
        .disabled(phase != .listening)
        .accessibilityLabel("Finish simulated dictation")
        .help("Preview the processing and completion states")
    }
}

private struct PreviewScene: View {
    let backdrop: PreviewBackdrop
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if backdrop == .aurora {
                    Color(red: 0.06, green: 0.10, blue: 0.21)
                    Ellipse().fill(Color(red: 0.17, green: 0.40, blue: 0.81))
                        .frame(width: 410, height: 230).blur(radius: 35)
                        .rotationEffect(.degrees(-28)).offset(x: -150, y: 45)
                    Ellipse().fill(Color(red: 0.44, green: 0.30, blue: 0.72))
                        .frame(width: 310, height: 110).blur(radius: 26)
                        .rotationEffect(.degrees(-30)).offset(x: 80, y: -20)
                    Ellipse().fill(Color(red: 0.23, green: 0.65, blue: 0.70).opacity(0.8))
                        .frame(width: 320, height: 66).blur(radius: 20)
                        .rotationEffect(.degrees(-30)).offset(x: -80, y: 140)
                } else {
                    (backdrop == .light ? Color(red: 0.96, green: 0.95, blue: 0.93) : Color(white: 0.09))
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(0..<4) { index in
                                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(index == 0 ? 0.12 : 0.06))
                                    .frame(width: index == 0 ? 55 : 42, height: 6)
                            }
                            Spacer()
                        }.padding(18).frame(width: 92)
                            .background(.primary.opacity(0.025))
                        VStack(alignment: .leading, spacing: 10) {
                            Text("A little space to think").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.30))
                            ForEach(0..<4) { index in
                                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.07))
                                    .frame(width: max(50, geometry.size.width - CGFloat(150 + index * 18)), height: 5)
                            }
                            Spacer()
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 18)
                }
            }
            .environment(\.colorScheme, backdrop.scheme)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }.accessibilityHidden(true)
    }
}

private struct StyleCard: View {
    let style: RecordingStyle
    @ObservedObject var model: GlassPreviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                PreviewScene(backdrop: model.backdrop)
                RecordingGlassBar(style: style, phase: model.phase, animate: model.animate, onStop: model.finish)
                    .environment(\.colorScheme, model.backdrop.scheme)
            }
            .frame(height: 178)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%02d", style.rawValue))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    Text(style.name).font(.headline)
                    Spacer()
                    Text(style.dimensions).font(.caption).foregroundStyle(.secondary)
                }
                Text(style.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    if model.floatingStyle == style {
                        Label("On your desktop", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(style == .clear ? "Clear glass" : style == .compact ? "Tinted regular glass" : "Regular glass")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { model.float(style) } label: {
                        Label(model.floatingStyle == style ? "Show again" : "Float on desktop", systemImage: "arrow.up.right.square")
                    }.controlSize(.small)
                        .accessibilityLabel("Float \(style.name) on desktop")
                }.padding(.top, 5)
            }.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct GlassGallery: View {
    @ObservedObject var model: GlassPreviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("VOXA  /  RECORDING BAR").font(.system(size: 10, weight: .semibold)).tracking(2)
                        .foregroundStyle(.secondary)
                    Text("Four ways to float.").font(.system(size: 30, weight: .semibold))
                    Text("Compare Liquid Glass at actual size. Float a style over your desktop to try it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Animate", isOn: $model.animate).toggleStyle(.switch).controlSize(.small)
                    .fixedSize()
            }
            HStack(spacing: 20) {
                HStack(spacing: 10) {
                    Text("Background").font(.callout).foregroundStyle(.secondary)
                    Picker("Background", selection: $model.backdrop) {
                        ForEach(PreviewBackdrop.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                Spacer()
                Picker("Recording state", selection: Binding(get: { model.phase }, set: { model.showPhase($0) })) {
                    ForEach(PreviewPhase.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                Button(action: model.replay) { Image(systemName: "arrow.counterclockwise") }
                    .help("Replay recording").accessibilityLabel("Replay recording")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], spacing: 20) {
                ForEach(RecordingStyle.originals) { StyleCard(style: $0, model: model) }
            }
            HStack {
                Label("Simulated audio · Your current recording bar stays unchanged", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Combined preview") { model.showOriginals = false }.controlSize(.small)
                if let floating = model.floatingStyle {
                    Text("\(String(format: "%02d", floating.rawValue)) on desktop").font(.caption).foregroundStyle(.secondary)
                    Button("Hide floating preview", action: model.hideFloating).controlSize(.small)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 980, idealWidth: 1040, maxWidth: 1200)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.watchGalleryClose() }
        .onExitCommand { model.hideFloating() }
    }
}

private struct CombinedGallery: View {
    @ObservedObject var model: GlassPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("VOXA  /  REFINED PREVIEW").font(.system(size: 10, weight: .semibold))
                        .tracking(2).foregroundStyle(.secondary)
                    Text("Compact. Native to your Mac.").font(.system(size: 28, weight: .semibold))
                    Text("Adaptive glass, one clear action, and standard macOS status colors.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Animate", isOn: $model.animate).toggleStyle(.switch).controlSize(.small).fixedSize()
            }

            HStack(spacing: 20) {
                HStack(spacing: 10) {
                    Text("Background").font(.callout).foregroundStyle(.secondary).fixedSize()
                    Picker("Background", selection: $model.backdrop) {
                        ForEach(PreviewBackdrop.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                Spacer()
                Picker("Recording state", selection: Binding(get: { model.phase }, set: { model.showPhase($0) })) {
                    ForEach(PreviewPhase.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                Button(action: model.replay) { Image(systemName: "arrow.counterclockwise") }
                    .help("Replay recording").accessibilityLabel("Replay recording")
            }

            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    PreviewScene(backdrop: model.backdrop)
                    RecordingGlassBar(style: .combined, phase: model.phase, animate: model.animate, onStop: model.finish)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.colorScheme, model.backdrop.scheme)
                    Text("ACTUAL SIZE  ·  " + RecordingStyle.combined.dimensions.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(model.backdrop == .light ? Color.black.opacity(0.45) : Color.white.opacity(0.6))
                        .padding(18)
                }.frame(height: 220)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compact native").font(.headline)
                        Text("A clear recording control. A quieter finish.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.float(.combined) } label: {
                        Label("Float on desktop", systemImage: "arrow.up.right.square")
                    }.buttonStyle(.borderedProminent)
                        .accessibilityLabel("Float combined compact bar on desktop")
                }.padding(18).background(Color(nsColor: .controlBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07), lineWidth: 1))

            HStack(spacing: 16) {
                ForEach(PreviewPhase.allCases) { phase in
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack {
                            PreviewScene(backdrop: model.backdrop)
                            RecordingGlassBar(style: .combined, phase: phase, animate: model.animate, onStop: model.finish)
                                .environment(\.colorScheme, model.backdrop.scheme)
                        }.frame(height: 108)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phase.rawValue).font(.headline)
                            Text(phase == .listening ? "System red · Finish recording" :
                                 phase == .processing ? "One spinner · No inactive controls" : "System green · Text ready")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 1))
                }
            }

            HStack {
                Label("Simulated audio", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.floatingStyle != nil {
                    Button("Hide floating preview", action: model.hideFloating).controlSize(.small)
                }
                Button("Original four styles") { model.showOriginals = true }.controlSize(.small)
            }
        }
        .padding(28)
        .frame(minWidth: 920, idealWidth: 980, maxWidth: 1200)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.watchGalleryClose() }
        .onExitCommand { model.hideFloating() }
    }
}

@main
private struct RecordingStylesPreviewApp: App {
    @StateObject private var model = GlassPreviewModel()
    var body: some Scene {
        Window("Voxa · Liquid Glass", id: "glass-gallery") {
            Group {
                if model.showOriginals { GlassGallery(model: model) }
                else { CombinedGallery(model: model) }
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1040, height: 850)
        .commands {
            CommandMenu("Preview") {
                ForEach(RecordingStyle.allCases) { style in
                    Button("Float \(style.name)") { model.float(style) }
                        .keyboardShortcut(KeyEquivalent(Character(String(style.rawValue))), modifiers: .command)
                }
                Divider()
                Button("Hide floating preview", action: model.hideFloating).keyboardShortcut(.escape, modifiers: [])
                Button("Replay recording", action: model.replay).keyboardShortcut("r")
            }
        }
    }
}
