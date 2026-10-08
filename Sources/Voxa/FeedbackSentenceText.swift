import AppKit
import SwiftUI

/// Native controls in a baseline-aligned sentence, so corrections can be explored
/// by pointer, keyboard, or VoiceOver without opening a separate popover.
struct FeedbackMarkedText: View {
    enum Mode { case inline, improved, suggestion }
    let original: String
    let suggestion: String
    let mode: Mode
    var activeRuns: Set<Int> = []
    var interactiveRuns: Set<Int> = []
    var onKeyboardExplore: (Int) -> Void = { _ in }
    var onExplore: (Int) -> Void = { _ in }
    var onSelect: (Int) -> Void = { _ in }
    @FocusState private var focusedRun: Int?
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Piece: Identifiable {
        let id: Int
        let run: Int
        var text: String
        let changed: Bool
        let removed: Bool
        let spaceBefore: Bool
        let newLine: Bool
    }

    private var pieces: [Piece] {
        var result: [Piece] = []
        var space = false
        var newLine = false
        let runs = FeedbackEditPresentation(original: original, suggestion: suggestion).runs
        for (index, run) in runs.enumerated() {
            let value: String
            let changed: Bool
            let removed: Bool
            switch run {
            case .unchanged(let text): value = text; changed = false; removed = false
            case .change(let before, let after):
                value = after.isEmpty && mode == .inline ? before : after
                changed = mode != .suggestion
                removed = after.isEmpty
            }
            if value.first?.isWhitespace == true { space = true }
            if value.hasPrefix("\n") { newLine = true }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if changed {
                result.append(Piece(id: result.count, run: index, text: trimmed, changed: true,
                                    removed: removed, spaceBefore: space, newLine: newLine))
                space = false; newLine = false
            } else {
                // Words stay in reading order; whitespace controls the flow spacing.
                var word = ""
                func flush() {
                    guard !word.isEmpty else { return }
                    result.append(Piece(id: result.count, run: index, text: word, changed: false,
                                        removed: false, spaceBefore: space, newLine: newLine))
                    word = ""; space = false; newLine = false
                }
                for character in value {
                    if character.isWhitespace {
                        flush(); space = true
                        if character.isNewline { newLine = true }
                    } else { word.append(character) }
                }
                flush()
            }
            if value.last?.isWhitespace == true { space = true }
            if value.hasSuffix("\n") { newLine = true }
        }
        return result
    }

    var body: some View {
        FeedbackSentenceFlow {
            ForEach(pieces) { piece in
                Group {
                    if piece.changed, interactiveRuns.contains(piece.run) {
                        Button { onSelect(piece.run) } label: { chip(piece) }
                            .buttonStyle(.plain)
                            .focused($focusedRun, equals: piece.run)
                            .onHover { if $0 { onExplore(piece.run) } }
                            .accessibilityLabel(piece.removed ? "Remove “\(piece.text)”" : "Correction: \(piece.text)")
                            .accessibilityHint("Show the explanation for this correction")
                            .accessibilityValue(activeRuns.contains(piece.run) ? "Explanation shown" : "")
                    } else if piece.changed { chip(piece) }
                    else { Text(piece.text).font(.system(size: 16, weight: .medium)) }
                }
                .layoutValue(key: FeedbackWordSpacing.self, value: piece.spaceBefore ? 3.5 : 0)
                .layoutValue(key: FeedbackWordBreak.self, value: piece.newLine)
            }
        }
        .onChange(of: focusedRun) { if let run = $0 { onKeyboardExplore(run) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .inline ? "You said: \(original) Corrected: \(suggestion)" : suggestion)
    }

    private func chip(_ piece: Piece) -> some View {
        let active = activeRuns.contains(piece.run) || focusedRun == piece.run
        return Text(piece.text)
            .font(.system(size: 16, weight: .semibold))
            .strikethrough(piece.removed)
            .foregroundStyle(Color(nsColor: piece.removed ? FeedbackInk.removed : FeedbackInk.added))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(nsColor: piece.removed ? FeedbackInk.removed.withAlphaComponent(0.12) : FeedbackInk.addedBackground)
                .opacity(active ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: piece.removed ? FeedbackInk.removed : FeedbackInk.added)
                    .opacity(active ? 0.65 : contrast == .increased ? 0.6 : 0.14), lineWidth: active ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum FeedbackWordSpacing: LayoutValueKey { static let defaultValue: CGFloat = 0 }
private enum FeedbackWordBreak: LayoutValueKey { static let defaultValue = false }

private struct FeedbackSentenceFlow: Layout {
    private struct Placement { let index: Int; var point: CGPoint; let size: CGSize }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [Placement]) {
        var placements: [Placement] = []
        var row: [(Int, ViewDimensions, CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, widest: CGFloat = 0
        func flush() {
            guard !row.isEmpty else { return }
            let ascent = row.map { $0.1[.firstTextBaseline] }.max() ?? 0
            let descent = row.map { $0.1.height - $0.1[.firstTextBaseline] }.max() ?? 0
            for (index, dimensions, offset) in row {
                placements.append(Placement(index: index,
                    point: CGPoint(x: offset, y: y + ascent - dimensions[.firstTextBaseline]),
                    size: CGSize(width: dimensions.width, height: dimensions.height)))
            }
            widest = max(widest, x); y += ascent + descent + 8
            row = []; x = 0
        }
        for (index, view) in subviews.enumerated() {
            let dimensions = view.dimensions(in: ProposedViewSize(width: width, height: nil))
            var gap = row.isEmpty ? 0 : view[FeedbackWordSpacing.self]
            // Keep attached punctuation with the preceding word where possible.
            let nextWidth: CGFloat = index + 1 < subviews.count && subviews[index + 1][FeedbackWordSpacing.self] == 0
                ? subviews[index + 1].sizeThatFits(.unspecified).width : 0
            if !row.isEmpty && (view[FeedbackWordBreak.self] || x + gap + dimensions.width + nextWidth > width) {
                flush(); gap = 0
            }
            row.append((index, dimensions, x + gap)); x += gap + dimensions.width
        }
        flush()
        return (CGSize(width: width, height: max(0, y - 8)), placements)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: max(1, proposal.width ?? FeedbackReviewView.width - 56), subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for item in arrangement(width: max(1, bounds.width), subviews: subviews).1 {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.point.x, y: bounds.minY + item.point.y),
                                      proposal: ProposedViewSize(item.size))
        }
    }
}
