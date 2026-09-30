import SwiftUI

/// Stages, not logs: a progress ring over the footage and a four-step
/// checklist. Raw job folders and log lines live in Settings → Diagnostics.
///
/// A blend is a JOB that can pause and resume (2026-09-30, `BlendJobs.swift`;
/// mirrors `processing{,.pausing,.paused,.resumed}.portrait.svg`): Pause
/// stops it after the frame being made with everything finished kept; the
/// paused screen offers Resume, Resume Later (the job waits on its project)
/// and Cancel.
struct ProcessingView: View {
    @EnvironmentObject var model: AppModel
    /// The run-rate values — ring fraction, frame counts, ETA, the hero —
    /// live on their own observable so their 10 Hz cadence re-evaluates this
    /// screen alone, not the whole app (see `ProcessingProgressModel`).
    @EnvironmentObject var progressModel: ProcessingProgressModel

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

            controls
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
        .background(LL.screenBackground.ignoresSafeArea())
    }

    // MARK: - Controls

    private var isPaused: Bool { model.blendJobHold != nil }

    /// Running: Pause · Cancel. Paused: Resume over Resume Later · Cancel —
    /// the pair sits exactly where Pause · Cancel sat.
    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            if isPaused {
                VStack(spacing: 12) {
                    Button {
                        model.resumeHeldBlendJob()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(LLPrimaryButtonStyle())

                    HStack(spacing: 12) {
                        Button("Resume Later") {
                            // The job stays on its project, where its card
                            // offers it again.
                            model.finishFlow(openProject: true)
                        }
                        .buttonStyle(LLSecondaryButtonStyle(tint: .primary))

                        Button("Cancel") {
                            model.cancelProcessing()
                        }
                        .buttonStyle(LLSecondaryButtonStyle(tint: .red))
                    }
                }
                caption("Resume Later keeps this blend on the project until you come back to it. Cancel discards it — your original is safe.")
            } else {
                HStack(spacing: 12) {
                    pauseButton

                    Button("Cancel") {
                        model.cancelProcessing()
                    }
                    .buttonStyle(LLSecondaryButtonStyle(tint: .red))
                }
                caption(model.isBlendJobRunning
                    ? "Pause keeps what's blended so far. Cancel discards it — your original is safe."
                    : "Cancelling discards this blended clip. Your original is safe.")
            }
        }
    }

    /// Pause, and — the moment after — "Pausing…" while the engine closes the
    /// piece it is writing (usually under a second).
    private var pauseButton: some View {
        let pausing = model.blendJobPausing
        return Button {
            model.pauseBlendJob()
        } label: {
            if pausing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.secondary)
                    Text("Pausing…")
                }
            } else {
                Label("Pause", systemImage: "pause.fill")
            }
        }
        .buttonStyle(LLSecondaryButtonStyle(tint: pausing ? Color.secondary.opacity(0.7) : .primary))
        .disabled(pausing || !model.isBlendJobRunning)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Preview + ring

    private var previewCard: some View {
        ZStack {
            // Resolved once per run in `startProcessing` — resolving it here
            // walked every source frame's existence on the main actor at
            // every progress tick.
            ProjectThumbnailView(
                url: progressModel.heroURL,
                kind: progressModel.heroKind
            )
            .frame(height: 260)
            .frame(maxWidth: .infinity)
            .blur(radius: 2.5)
            // A touch darker than the rest of the app's scrims: the mark's
            // silver pipe has to hold against a bright frame behind it.
            .overlay(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            LLRigProgress(progress: progressModel.fraction, paused: isPaused)
        }
        .overlay(alignment: .bottom) {
            if isPaused {
                HStack(spacing: 5) {
                    Image(systemName: "pause.fill")
                    Text("Paused")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.5), in: Capsule())
                .padding(.bottom, 14)
            }
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
            } else if stage == current, isPaused {
                // Held, not moving: grey, where amber means running (the
                // status scheme of 2026-09-26).
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
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
        guard let done = progressModel.framesDone,
              let total = progressModel.framesTotal, total > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let processedText = formatter.string(from: NSNumber(value: done)) ?? "\(done)"
        let totalText = formatter.string(from: NSNumber(value: total)) ?? "\(total)"
        return "\(processedText) / \(totalText)"
    }

    // MARK: - ETA

    private func timeRemainingText(at now: Date) -> String {
        if isPaused {
            let percent = Int((min(1, max(0, progressModel.fraction)) * 100).rounded())
            return "Paused at \(percent)% — resuming picks up where it stopped"
        }
        if model.blendJobPausing {
            return "Saving progress…"
        }
        if let until = model.blendResumedNoticeUntil, now < until {
            // The note takes the clip position's place: both do not fit.
            let rest = progressModel.etaDate.map { eta in
                let remaining = eta.timeIntervalSince(now)
                return remaining > 0 ? remainingPhrase(remaining) : "Almost done"
            } ?? phaseLabel
            return "Picked up where it left off · \(rest)"
        }
        if let eta = progressModel.etaDate {
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
        case .slicing:
            return "Time slicing..."
        case .posterFrames(0, _, _):
            return "Preparing the poster..."
        case .posterFrames(let frames, let of, 1):
            return "Rendering \(frames) of \(of) frames for the poster..."
        case .posterFrames(let frames, let of, let posters):
            return "Rendering \(frames) of \(of) frames for \(posters) posters..."
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
