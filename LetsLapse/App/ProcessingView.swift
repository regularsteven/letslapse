import SwiftUI

/// Stages, not logs: a progress ring over the footage and a four-step
/// checklist. Raw job folders and log lines live in Settings → Diagnostics.
struct ProcessingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            previewCard
                .padding(.top, 24)

            stageChecklist

            // TimelineView survives the constant progress-driven re-renders
            // that would reset a view-owned Timer publisher.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = timeRemainingText(at: context.date)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .opacity(text.isEmpty ? 0 : 1)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Button {
                    model.cancelProcessing()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(LLSecondaryButtonStyle(tint: .red))

                Text("Cancelling discards this blended clip. Your original is safe.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
        .background(LL.screenBackground.ignoresSafeArea())
    }

    // MARK: - Preview + ring

    private var previewCard: some View {
        ZStack {
            ProjectThumbnailView(
                url: model.currentCapture.flatMap { model.mediaURL(for: $0) },
                kind: model.currentCapture.map { model.mediaKind(for: $0) } ?? .video
            )
            .frame(height: 260)
            .frame(maxWidth: .infinity)
            .blur(radius: 2.5)
            // A touch darker than the rest of the app's scrims: the mark's
            // silver pipe has to hold against a bright frame behind it.
            .overlay(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            LLRigProgress(progress: model.progress)
        }
    }

    // MARK: - Checklist

    private var stageChecklist: some View {
        VStack(spacing: 0) {
            ForEach(AppModel.ProcessingStage.allCases, id: \.rawValue) { stage in
                stageRow(stage)
            }
        }
        .padding(.vertical, 6)
        .llCard()
    }

    @ViewBuilder
    private func stageRow(_ stage: AppModel.ProcessingStage) -> some View {
        let current = model.processingStage
        HStack(spacing: 12) {
            if stage < current {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 18)
            } else if stage == current {
                Circle()
                    .fill(LL.amber)
                    .frame(width: 9, height: 9)
                    .frame(width: 18)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1.2)
                    .frame(width: 9, height: 9)
                    .frame(width: 18)
            }

            Text(stage.title)
                .font(.system(size: 15, weight: stage == current ? .semibold : .regular))
                .foregroundStyle(stage <= current ? Color.primary : Color.secondary.opacity(0.7))

            Spacer()

            if stage == .blending, current == .blending, let counts = blendingCounts {
                Text(counts)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var blendingCounts: String? {
        // Whole-run counts from the progress plan, both platforms — never a
        // number synthesized from the ring's position.
        guard let done = model.processingFramesDone,
              let total = model.processingFramesTotal, total > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let processedText = formatter.string(from: NSNumber(value: done)) ?? "\(done)"
        let totalText = formatter.string(from: NSNumber(value: total)) ?? "\(total)"
        return "\(processedText) / \(totalText)"
    }

    // MARK: - ETA

    private func timeRemainingText(at now: Date) -> String {
        if let eta = model.processingETADate {
            let remaining = eta.timeIntervalSince(now)
            let phrase = remaining > 0 ? remainingPhrase(remaining) : "Almost done"
            if case .blending(let clip, let of) = model.processingPhase, of > 1 {
                return "\(phrase) · Clip \(clip) of \(of)"
            }
            return phrase
        }
        return phaseLabel
    }

    /// What's actually happening when there's no countdown to show yet.
    private var phaseLabel: String {
        switch model.processingPhase {
        case .preparing:
            return "Preparing footage..."
        case .blending(_, 1):
            return "Blending frames..."
        case .blending(let clip, let of):
            return "Blending clip \(clip) of \(of)..."
        case .combining(let clips):
            return "Combining \(clips) clips..."
        case .grading:
            return "Applying the colour grade..."
        case .saving:
            return "Almost done"
        }
    }

    private func remainingPhrase(_ remaining: TimeInterval) -> String {
        if remaining < 8 {
            return "Almost done"
        }
        if remaining < 90 {
            let rounded = Int((remaining / 5).rounded() * 5)
            return "About \(rounded) seconds left"
        }
        if remaining < 90 * 60 {
            let minutes = Int((remaining / 60).rounded())
            return "About \(minutes) minute\(minutes == 1 ? "" : "s") left"
        }
        let halfHours = (remaining / 3600 * 2).rounded() / 2
        let text = halfHours == halfHours.rounded() ? String(format: "%.0f", halfHours) : String(format: "%.1f", halfHours)
        return "About \(text) hour\(halfHours == 1 ? "" : "s") left"
    }

}
