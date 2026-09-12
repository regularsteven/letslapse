import SwiftUI
import LetsLapseKit

/// Runs "Find shapes" over every project without a register, with a
/// determinate progress card, and reports what it found.
struct FindShapesView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var finder = ShapeFinder()
    var onFinished: () -> Void = {}

    @State private var pending: (todo: Int, alreadyDone: Int, skippedVideo: Int, outdated: Int) = (0, 0, 0, 0)
    @State private var started = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress = finder.progress {
                    progressCard(progress)
                } else if let summary = finder.summary {
                    summaryCard(summary)
                } else {
                    plan
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Find shapes")
        .onAppear {
            let c = ShapeFinder.candidates(in: model)
            pending = (c.todo.count, c.alreadyDone, c.skippedVideo, c.outdated)
        }
        .onDisappear {
            if finder.isRunning { finder.cancel() }
        }
        .onChange(of: finder.summary) { summary in
            if summary != nil { onFinished() }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.todo == 0 ? "Every project has been checked." : "\(pending.todo) project\(pending.todo == 1 ? "" : "s") to analyse")
                .font(.system(size: 17, weight: .semibold))
            Text("One picture per project — the rendered blend where there is one, else the middle frame — is searched for circles, ovals, squares and rectangles. Results are kept with the project; a project is analysed again only when the detector has improved, and shapes you kept or drew stay.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if pending.alreadyDone > 0 || pending.skippedVideo > 0 || pending.outdated > 0 {
                Text("\(pending.alreadyDone) already analysed" + (pending.outdated > 0 ? " · \(pending.outdated) from an older detector" : "") + " · \(pending.skippedVideo) video shoot\(pending.skippedVideo == 1 ? "" : "s") left out")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            if pending.todo > 0 {
                Button {
                    started = true
                    finder.run(model: model)
                } label: {
                    Text("Find shapes")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func progressCard(_ progress: ShapeFinder.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
                Text("Analysing \(progress.done + 1) of \(progress.total)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Stop") { finder.cancel() }
                    .font(.system(size: 13))
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(LL.accent)
            Text(progress.current)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    private func summaryCard(_ summary: ShapeFinder.Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.analysed == 0 ? "Nothing new to analyse" : "\(summary.analysed) project\(summary.analysed == 1 ? "" : "s") analysed")
                .font(.system(size: 17, weight: .semibold))
            Text("\(summary.withShapes) with at least one shape")
                .font(.system(size: 14))
            HStack(spacing: 8) {
                ForEach(DetectedShape.Family.allCases, id: \.self) { family in
                    let n = summary.families[family] ?? 0
                    Label("\(n)", systemImage: family.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(n == 0 ? .tertiary : .primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background((n == 0 ? Color.secondary : LL.accent).opacity(0.12), in: Capsule())
                }
            }
            if summary.unreadable > 0 {
                Text("\(summary.unreadable) picture\(summary.unreadable == 1 ? "" : "s") could not be read.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }
}
