import SwiftUI
import LetsLapseKit

#if os(macOS)
/// One review window per project; reopening fronts it (same pattern as the
/// photo and video editors — a macOS sheet is never user-resizable, and this
/// one has a chart worth a real window).
struct FramingReviewWindowRequest: Hashable, Codable {
    let captureID: UUID
    let title: String
}
#endif

/// The framing review over an interval shoot's stills — "Review photos" on
/// the project screen. Two states: measuring (progress over
/// `FramingMeasurement`, cancellable) and the report (`FramingReview`:
/// verdict, the path over the shoot, the knocks, the plan, and the button
/// that commits the plan as metadata). Specs:
/// docs/design/iOS/framing-review*.portrait.svg and
/// docs/design/macOS/framing-review*.svg.
struct FramingReviewView: View {
    let captureID: UUID
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = FramingReviewStore.shared
    @Environment(\.dismiss) private var dismiss

    private var capture: AppModel.CaptureProject? {
        model.capture(id: captureID)
    }

    private var review: FramingReview? { store.review(for: captureID) }
    private var run: FramingReviewStore.Run? { store.run(for: captureID) }

    var body: some View {
        content
            .onAppear(perform: beginIfNeeded)
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            macHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let run {
                        measuring(run)
                    } else if let review {
                        summaryLines(review)
                        sectionTitle("FRAMING OVER THE SHOOT")
                        pathCard(review)
                        sectionTitle("KNOCKS · \(review.events.count)")
                        knocksCard(review)
                        planCard(review)
                    } else if let failure = store.failure(for: captureID) {
                        Text(failure).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            Divider()
            macFooter
        }
        .frame(width: 560, height: 640)
        .background(LL.screenBackground)
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(subtitleLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    if let run {
                        measuringCard(run)
                    } else if let review {
                        verdictCard(review)
                        sectionTitle("FRAMING OVER THE SHOOT")
                        pathCard(review)
                        sectionTitle("KNOCKS · \(review.events.count)")
                        knocksCard(review)
                        planCard(review)
                        primaryButton(review)
                        Text("Nothing on disk changes. Undo any time from the project screen.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else if let failure = store.failure(for: captureID) {
                        Text(failure).foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(LL.screenBackground)
            .navigationTitle("Framing review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }

    // MARK: - Lifecycle

    private func beginIfNeeded() {
        guard let capture else { return }
        let folder = model.sourceFolderURL(for: capture)
        store.load(id: captureID, sourceFolder: folder)
        // Opened with no review on file: the review is what was asked for.
        if store.isLoaded(captureID), store.review(for: captureID) == nil, !store.isMeasuring(captureID) {
            startReview()
        } else if !store.isLoaded(captureID) {
            // The sidecar is still being read; decide once it has.
            Task { @MainActor in
                while !store.isLoaded(captureID) { try? await Task.sleep(nanoseconds: 50_000_000) }
                if store.review(for: captureID) == nil, !store.isMeasuring(captureID) { startReview() }
            }
        }
    }

    private func startReview() {
        guard let capture else { return }
        store.startReview(
            id: captureID, urls: model.sourceFrameURLs(for: capture),
            sourceFolder: model.sourceFolderURL(for: capture))
    }

    private func commit() {
        guard let capture else { return }
        store.stabilise(id: captureID, sourceFolder: model.sourceFolderURL(for: capture))
        model.refreshFramingLockIfOpen(capture)
    }

    private func withdraw() {
        guard let capture else { return }
        store.withdraw(id: captureID, sourceFolder: model.sourceFolderURL(for: capture))
        model.refreshFramingLockIfOpen(capture)
    }

    // MARK: - Copy

    private var subtitleLine: String {
        guard let capture else { return "" }
        var parts = [capture.displayTitle, "\(model.sourceFrameURLs(for: capture).count) photos"]
        if let width = capture.sourceWidth, let height = capture.sourceHeight {
            parts.append("\(width)×\(height)")
        }
        return parts.joined(separator: " · ")
    }

    private func headline(_ review: FramingReview) -> String {
        switch review.verdict {
        case .recommended: return "Stabilisation recommended"
        case .steady: return "Framing steady"
        case .inconclusive: return "Framing not judged"
        }
    }

    private func headlineGlyph(_ review: FramingReview) -> some View {
        Group {
            switch review.verdict {
            case .recommended:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LL.amber)
            case .steady:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .inconclusive:
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 20))
    }

    private func cropLine(_ review: FramingReview) -> String {
        let kept = Int((Double(review.width) * (1 - review.plan.cropFraction)).rounded(.down))
        let keptHeight = Int((Double(review.height) * (1 - review.plan.cropFraction)).rounded(.down))
        return "Crops \(FramingReviewStore.percent(review.plan.cropFraction)) · keeps \(kept)×\(keptHeight) of \(review.width)×\(review.height)"
    }

    // MARK: - Blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    private func measuringCard(_ run: FramingReviewStore.Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measuring the framing").font(.system(size: 16, weight: .semibold))
            progressBar(run.progress)
            HStack {
                Text("Photo \(max(1, Int(run.progress * Double(run.total)))) of \(run.total)")
                    .monospacedDigit()
                Spacer()
                Text(timeLeft(run)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 13))
            Text("Each photo is matched against its neighbours to find where the framing moved. Nothing on disk changes — the review is written beside the photos and the fix is metadata until you apply it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { store.cancel(id: captureID) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(16)
        .llCard()
    }

    private func measuring(_ run: FramingReviewStore.Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            progressBar(run.progress)
            HStack {
                Text("Photo \(max(1, Int(run.progress * Double(run.total)))) of \(run.total)").monospacedDigit()
                Spacer()
                Text(timeLeft(run)).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Text("Each photo is matched against its neighbours to find where the framing moved. Nothing on disk changes — the review is written beside the photos, and the fix stays metadata until you apply it.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(LL.accent).frame(width: max(6, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
    }

    private func timeLeft(_ run: FramingReviewStore.Run) -> String {
        guard let seconds = run.secondsLeft else { return "Estimating…" }
        if seconds < 90 { return "About \(max(5, Int(seconds / 5) * 5)) seconds left" }
        let minutes = Int((seconds / 60).rounded())
        return "About \(minutes) minute\(minutes == 1 ? "" : "s") left"
    }

    private func verdictCard(_ review: FramingReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                headlineGlyph(review)
                Text(headline(review)).font(.system(size: 16, weight: .semibold))
                if review.isStabilisationCurrent {
                    Spacer()
                    Label("Stabilised", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            Text(review.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    private func summaryLines(_ review: FramingReview) -> some View {
        Text(review.summary)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    private func pathCard(_ review: FramingReview) -> some View {
        FramingPathChart(review: review)
            .frame(height: 112)
            .padding(8)
            .llCard()
    }

    private func knocksCard(_ review: FramingReview) -> some View {
        VStack(spacing: 0) {
            if review.events.isEmpty {
                Text("No knocks. Every photo sits within \(String(format: "%.1f", FramingReview.eventThresholdPixels)) px of its neighbours.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let ordered = review.events.sorted { $0.peakPixels > $1.peakPixels }
            ForEach(Array(ordered.prefix(12).enumerated()), id: \.offset) { index, event in
                knockRow(event)
                if index < min(ordered.count, 12) - 1 {
                    Divider().padding(.leading, 16)
                }
            }
            if ordered.count > 12 {
                Divider().padding(.leading, 16)
                Text("and \(ordered.count - 12) more")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
        }
        .llCard()
    }

    private func knockRow(_ event: FramingReview.Event) -> some View {
        let first = FramingReview.displayNumber(name: event.firstName, index: event.firstIndex)
        let last = FramingReview.displayNumber(name: event.lastName, index: event.lastIndex)
        let range = first == last ? "Photo \(first)" : "Photos \(first)–\(last)"
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(range).font(.system(size: 14.5))
                Text("\(event.count) photo\(event.count == 1 ? "" : "s")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .leading) {
                Capsule().fill(LL.controlFill).frame(width: 90, height: 6)
                Capsule().fill(LL.amber).frame(width: 90 * min(1, event.peakPixels / 10), height: 6)
            }
            Text(String(format: "%.1f px", event.peakPixels))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func planCard(_ review: FramingReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THE FIX")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LL.amber)
                .tracking(0.5)
            Text("Lock every photo to one framing")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(review.plan.summary.replacingOccurrences(of: "Lock every photo to one framing: shift", with: "Shift"))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Text(cropLine(review))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LL.amber)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func primaryButton(_ review: FramingReview) -> some View {
        Button {
            if review.isStabilisationCurrent { withdraw() } else { commit() }
        } label: {
            Text(review.isStabilisationCurrent ? "Undo stabilisation" : "Stabilise photos")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(review.isStabilisationCurrent ? LL.accent : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(review.isStabilisationCurrent ? LL.cardBackground : LL.accent))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // MARK: - macOS chrome

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            if let review, run == nil {
                headlineGlyph(review)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(headline(review)).font(.system(size: 14, weight: .bold))
                        if review.isStabilisationCurrent {
                            Label("Stabilised", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(subtitleLine) · reviewed \(FramingReviewStore.reviewedAt(review.reviewedAt))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "scope").font(.system(size: 18)).foregroundStyle(LL.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measuring the framing").font(.system(size: 14, weight: .bold))
                    Text(subtitleLine).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var macFooter: some View {
        HStack {
            if run != nil {
                Spacer()
                Button("Cancel") { store.cancel(id: captureID) }
            } else if let review {
                Text("Nothing on disk changes. Undo any time from the project screen.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Review again") { startReview() }
                Button("Done") { dismiss() }
                if review.isStabilisationCurrent {
                    Button("Undo") { withdraw() }
                } else {
                    Button("Stabilise photos") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .tint(LL.accent)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    #endif
}

/// Every photo's vertical offset against the reference framing, on a
/// ±10 px scale (wider when a shoot needs it), knocks shaded amber. The
/// horizontal axis is not drawn: on a tripod the gravity axis is the one
/// that moves, and one line reads.
struct FramingPathChart: View {
    let review: FramingReview

    var body: some View {
        Canvas { context, size in
            let values = review.frames.map { $0.dy - review.plan.referenceY }
            guard values.count > 1 else { return }
            let labelWidth: CGFloat = 34
            let plot = CGRect(x: labelWidth, y: 6, width: size.width - labelWidth - 8, height: size.height - 20)
            let limit = max(10, ceil(values.map { abs($0) }.max() ?? 10))
            let mid = plot.midY
            let perPixel = (plot.height / 2) / limit
            func x(_ index: Int) -> CGFloat { plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1) }
            // Grid: ±limit dashed, zero solid.
            for (value, dashed) in [(limit, true), (0, false), (-limit, true)] {
                let y = mid - value * perPixel
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(.primary.opacity(dashed ? 0.06 : 0.12)),
                               style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 3] : []))
                let text = value == 0 ? "0" : String(format: "%@%.0f px", value > 0 ? "+" : "−", abs(value))
                context.draw(Text(text).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
            }
            // Knocks, shaded.
            for event in review.events {
                let rect = CGRect(x: x(event.firstIndex) - 2, y: plot.minY,
                                  width: max(4, x(event.lastIndex) - x(event.firstIndex) + 4), height: plot.height)
                context.fill(Path(rect), with: .color(LL.amber.opacity(0.22)))
            }
            // The path, one point per photo up to a few hundred; beyond that
            // the largest excursion per bucket, so a knock survives the
            // thinning.
            var path = Path()
            let buckets = min(values.count, 400)
            for bucket in 0..<buckets {
                let start = values.count * bucket / buckets
                let end = max(start + 1, values.count * (bucket + 1) / buckets)
                var pick = start
                for index in start..<end where abs(values[index]) > abs(values[pick]) { pick = index }
                let point = CGPoint(x: x(pick), y: mid - values[pick] * perPixel)
                if bucket == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(LL.accent), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            let first = FramingReview.displayNumber(name: review.frames[0].name, index: 0)
            let last = FramingReview.displayNumber(name: review.frames[values.count - 1].name, index: values.count - 1)
            context.draw(Text("photo \(first)").font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: plot.minX, y: size.height - 4), anchor: .bottomLeading)
            var end = "\(last)"
            if let span = review.captureSpanSeconds { end += " · \(FramingReview.duration(span))" }
            context.draw(Text(end).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: plot.maxX, y: size.height - 4), anchor: .bottomTrailing)
        }
    }
}
