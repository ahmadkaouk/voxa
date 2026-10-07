import SwiftUI

private typealias ProgressViewState<Value> = SwiftUI.State<Value>

struct LearningProgressView: View {
    @ObservedObject var progress: LearningProgress
    @ProgressViewState private var confirmClear = false
    private var profile: ExpressionProfile { progress.expressionProfile }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Progress").font(.title2.weight(.semibold))
                        Text("Patterns and expression from your everyday dictation.")
                            .font(.callout).foregroundStyle(.secondary)
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
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("English expression · Estimated from dictation")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text(profile.label).font(.system(size: profile.ready ? 34 : 24, weight: .medium))
                        Text(profile.ready ? profile.trend : profile.guidance).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(profile.coverage).font(.system(size: 11)).foregroundStyle(.secondary)
                        if profile.ready {
                            Divider().padding(.vertical, 2)
                            ForEach(ExpressionDimension.allCases, id: \.self) { dimension in
                                HStack {
                                    Text(dimension.label).font(.system(size: 13))
                                    Spacer()
                                    Text(ExpressionProfile.label(profile.median(dimension)))
                                        .font(.system(size: 13, weight: .medium)).foregroundStyle(FeedbackPalette.accent)
                                }
                            }
                            if let focus = profile.nextFocus {
                                Text("Try next · " + focus.practiceAdvice)
                                    .font(.system(size: 12, weight: .medium)).padding(.top, 6)
                            }
                        } else {
                            Text("Short or uncertain samples won’t pull your level down. Grammar-only history stays saved; the broader estimate starts with new dictations.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(ExpressionProfile.limitation).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)

                if !progress.patterns.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Patterns to practise").font(.system(size: 16, weight: .semibold))
                        Text("Correct uses need an actual example in your dictation. Practice exercises are tracked separately.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(progress.patterns) { pattern in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(pattern.focus.label).font(.system(size: 13, weight: .medium))
                                    Text(pattern.corrections > 0 ? "Corrections in \(pattern.corrections) dictations" :
                                            "Introduced in \(pattern.suggestions) dictations")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(pattern.successes) \(pattern.successes == 1 ? "correct use" : "correct uses")")
                                    .font(.system(size: 12)).foregroundStyle(pattern.successes > 0 ? FeedbackPalette.accent : .secondary)
                            }
                            Divider()
                        }
                    }
                }
                Text("Stored on this Mac: assessment bands, word counts, speaking-task categories and pattern counts from up to 200 dictations. The level estimate uses up to 30 qualifying samples from the last 90 days. No dictated text is kept in progress.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.frame(maxWidth: 680, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 500, idealWidth: 760, minHeight: 520, idealHeight: 600)
        .alert("Clear your learning progress?", isPresented: $confirmClear) {
            Button("Clear progress", role: .destructive) { progress.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes level and pattern history from this Mac. Your saved lessons and review timing stay available.") }
    }
}
