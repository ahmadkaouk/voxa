import Charts
import SwiftUI

private typealias ProgressViewState<Value> = SwiftUI.State<Value>

struct LearningProgressView: View {
    @ObservedObject var progress: LearningProgress
    @ProgressViewState private var confirmClear = false

    private var scores: [Int] { Array(progress.recentScores.prefix(10).reversed()) }
    private var average: String {
        guard !scores.isEmpty else { return "—" }
        return String(format: "%.1f", Double(scores.reduce(0, +)) / Double(scores.count))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your English, over time.").font(.system(size: 23, weight: .semibold))
                        Text("Notice what repeats. Practise it. Notice when you use it well.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear progress…") { confirmClear = true }
                        .disabled(!progress.ready || progress.isSaving || progress.records.isEmpty)
                }
                if let error = progress.error {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { progress.retry() }.disabled(progress.isSaving)
                    }
                }
                if progress.records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 32, weight: .light)).foregroundStyle(FeedbackPalette.accent)
                        Text(progress.error != nil ? "Progress is temporarily unavailable." :
                                (progress.ready ? "Your next dictations start the picture." : "Opening your progress…"))
                            .font(.system(size: 17, weight: .medium))
                        Text("With English feedback on, grammar estimates and patterns build up here automatically.\nCorrect uses count too, even when there’s nothing to correct.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    HStack(alignment: .top, spacing: 36) {
                        VStack(alignment: .leading, spacing: 4) {
                            (Text(average).font(.system(size: 36, weight: .medium, design: .rounded))
                             + Text(" / 10").font(.system(size: 14)).foregroundColor(.secondary))
                            Text("Recent grammar estimate").font(.system(size: 12, weight: .medium))
                            Text(scores.isEmpty ? "Longer samples will add scores" : "Latest \(scores.count) scored reviews")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(minWidth: 190, alignment: .leading)
                        if !scores.isEmpty {
                            Chart(Array(scores.enumerated()), id: \.offset) { item in
                                LineMark(x: .value("Review", item.offset + 1), y: .value("Grammar estimate", item.element))
                                    .foregroundStyle(FeedbackPalette.accent)
                                PointMark(x: .value("Review", item.offset + 1), y: .value("Grammar estimate", item.element))
                                    .foregroundStyle(FeedbackPalette.accent).symbolSize(22)
                            }
                            .chartYScale(domain: 0...10).chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(values: [0, 5, 10]) { _ in
                                    AxisGridLine()
                                    AxisValueLabel(anchor: .leading)
                                }
                            }
                            .frame(height: 100)
                            .accessibilityLabel("Grammar estimates, oldest to newest: " + scores.map(String.init).joined(separator: ", "))
                        }
                    }.padding(20)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

                    if !progress.patterns.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Patterns to practise").font(.system(size: 16, weight: .semibold))
                            Text("Counts are per review. A correct use needs an actual example; silence doesn’t count as success.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            ForEach(progress.patterns) { pattern in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(pattern.focus.label).font(.system(size: 13, weight: .medium))
                                        Text(context(pattern)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(pattern.successes) \(pattern.successes == 1 ? "correct use" : "correct uses")")
                                        .font(.system(size: 12)).foregroundStyle(pattern.successes > 0 ? FeedbackPalette.accent : .secondary)
                                }
                                Divider()
                            }
                        }
                    }
                }
                Text("Stored on this Mac: score bands and pattern counts from up to 200 recent reviews. No dictated text is kept in progress. Optional alternatives don’t lower your score. Estimates describe grammar in the transcript, not pronunciation or overall speaking ability.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(28)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 600)
        .alert("Clear your learning progress?", isPresented: $confirmClear) {
            Button("Clear progress", role: .destructive) { progress.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes score and pattern history from this Mac. Your saved lessons stay available.") }
    }

    private func context(_ pattern: PatternProgress) -> String {
        if pattern.corrections > 0 {
            return "Corrections in \(pattern.corrections) \(pattern.corrections == 1 ? "review" : "reviews")"
        }
        if pattern.suggestions > 0 {
            return "Introduced in \(pattern.suggestions) \(pattern.suggestions == 1 ? "review" : "reviews")"
        }
        return "Keep using this pattern in new sentences"
    }
}
