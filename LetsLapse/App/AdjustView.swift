import SwiftUI
import LetsLapseKit

/// "Adjust" — pick a speed, see the one number that matters (how long the
/// clip will be), then create the version. Replaces the old Blend Options form.
struct AdjustView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdvanced = false
    @State private var showCustomSpeed = false

    var body: some View {
        VStack(spacing: 0) {
            FlowHeader(title: "New version") {
                model.reset()
            }

            ScrollView {
                VStack(spacing: 14) {
                    sourceCard

                    if model.source?.isVideo == true {
                        speedSection
                        estimateCard
                        advancedRow
                    } else {
                        stackCard
                    }

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .llCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            bottomBar
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .sheet(isPresented: $showAdvanced) {
            AdvancedOptionsSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showCustomSpeed) {
            CustomSpeedSheet()
                .environmentObject(model)
        }
    }

    // MARK: - Source

    private var sourceCard: some View {
        HStack(spacing: 12) {
            ProjectThumbnailView(
                url: model.currentCapture.flatMap { model.mediaURL(for: $0) },
                kind: model.currentCapture.map { model.mediaKind(for: $0) } ?? .video
            )
            .frame(width: 64, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentCapture?.displayTitle ?? "Source")
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(sourceDetailLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
            Button("Change") {
                model.reset()
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        .padding(12)
        .llCard()
    }

    private var sourceDetailLine: String {
        guard let capture = model.currentCapture else { return "—" }
        var parts: [String] = []
        if let duration = capture.sourceDurationSeconds {
            parts.append(DurationFormatter.recordingTime(from: duration) + " min")
        }
        parts.append(capture.formatLine)
        parts.append("shot \(capture.createdAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    // MARK: - Speed

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Speed")
            HStack(spacing: 8) {
                ForEach(SpeedMath.presets, id: \.self) { preset in
                    speedChip(
                        title: "\(preset)×",
                        subtitle: SpeedMath.chipWord(for: preset),
                        isSelected: !model.useRamp && model.constantWindow == preset
                    ) {
                        model.useRamp = false
                        model.constantWindow = preset
                    }
                }
                speedChip(
                    title: "···",
                    subtitle: "custom",
                    isSelected: !model.useRamp && !SpeedMath.presets.contains(model.constantWindow)
                ) {
                    showCustomSpeed = true
                }
            }
            if model.useRamp {
                Text("Speed ramp \(model.rampStart)×→\(model.rampEnd)× is on — edit it in Advanced.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func speedChip(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSelected ? LL.amber : .primary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isSelected ? LL.ink : LL.cardBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: .black.opacity(isSelected ? 0 : 0.05), radius: 1.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Estimate

    private var estimateCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your clip will be")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Menu {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                        Button {
                            model.outputFPS = fps
                        } label: {
                            if fps == model.outputFPS {
                                Label("\(fps) fps", systemImage: "checkmark")
                            } else {
                                Text("\(fps) fps")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(model.outputFPS) fps")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(estimateHeadline)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("· \(SpeedMath.cardPhrase(for: effectiveSpeed))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.amber)
            }
            .padding(.top, 2)
            .padding(.bottom, 10)

            if let sourceSeconds = model.currentCapture?.sourceDurationSeconds,
               let outputSeconds = model.estimatedOutputSeconds(), sourceSeconds > 0 {
                BeforeAfterBar(
                    sourceLabel: DurationFormatter.recordingTime(from: sourceSeconds),
                    outputLabel: SpeedMath.clipLengthCompact(outputSeconds),
                    ratio: outputSeconds / sourceSeconds
                )
                .padding(.bottom, 8)
            }

            Text(blurExplainer)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var effectiveSpeed: Int {
        model.useRamp ? max(1, (model.rampStart + model.rampEnd) / 2) : model.constantWindow
    }

    private var estimateHeadline: String {
        guard let seconds = model.estimatedOutputSeconds() else { return "— seconds" }
        let approx = model.useRamp ? "≈ " : ""
        if seconds < 9.95 {
            return approx + String(format: "%.1f seconds", seconds)
        }
        return approx + SpeedMath.clipLength(seconds)
    }

    private var blurExplainer: String {
        if model.useRamp {
            return "The window ramps from \(model.rampStart) to \(model.rampEnd) frames per output frame across the clip."
        }
        return "Each output frame averages \(model.constantWindow) real frames — that's where the blur comes from."
    }

    // MARK: - Photos stack

    private var stackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One silky still")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text("All \(model.currentCapture?.sourceMediaCount ?? 0) photos are averaged into a single synthetic long exposure. Noise drops by roughly the square root of the frame count.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))

            Toggle(isOn: $model.linearLight) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("True-light blending")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    Text("Blends in linear light — smoother highlights")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .tint(.green)
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Advanced

    private var advancedRow: some View {
        Button {
            showAdvanced = true
        } label: {
            HStack {
                Text("Advanced")
                    .font(.system(size: 15.5))
                    .foregroundStyle(.primary)
                Spacer()
                Text(advancedSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .llCard()
    }

    private var advancedSummary: String {
        var active: [String] = []
        if model.useRamp { active.append("Ramp on") }
        if model.trimVideoEnds { active.append("Trim on") }
        if model.linearLight { active.append("True-light") }
        return active.isEmpty ? "Ramp · Trim · True-light" : active.joined(separator: " · ")
    }

    // MARK: - CTA

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                model.startProcessing()
            } label: {
                Text(ctaTitle)
            }
            .buttonStyle(LLPrimaryButtonStyle())

            Text("Your original is kept — you can always make another version.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LL.screenBackground)
    }

    private var ctaTitle: String {
        if model.source?.isVideo == true {
            if let seconds = model.estimatedOutputSeconds() {
                return "Create \(SpeedMath.clipLength(seconds)) clip"
            }
            return "Create clip"
        }
        return "Create long exposure"
    }
}

// MARK: - Before/after bar

/// A proportional "3:45 → 2.2s" bar: the source as a long track, the output
/// as the sliver it becomes.
struct BeforeAfterBar: View {
    var sourceLabel: String
    var outputLabel: String
    var ratio: Double

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color(white: 0.24))
                .frame(height: 8)
                .frame(maxWidth: .infinity)
            Text(sourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            Capsule()
                .fill(LL.amber)
                .frame(width: max(8, min(48, 160 * ratio)), height: 8)
            Text(outputLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LL.amber)
                .fixedSize()
        }
        .frame(height: 14)
    }
}

// MARK: - Advanced sheet

struct AdvancedOptionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Ramp the speed across the clip", isOn: $model.useRamp)
                    if model.useRamp {
                        Stepper("Start: \(model.rampStart)×", value: $model.rampStart, in: SpeedMath.range)
                        Stepper("End: \(model.rampEnd)×", value: $model.rampEnd, in: SpeedMath.range)
                        Picker("Curve", selection: $model.curve) {
                            ForEach(BlendCurve.allCases, id: \.self) { curve in
                                Text(curve.rawValue).tag(curve)
                            }
                        }
                    }
                } header: {
                    Text("Speed ramp")
                } footer: {
                    Text("The blend window moves between two speeds over the length of the clip.")
                }

                Section {
                    Toggle("Trim video ends", isOn: $model.trimVideoEnds)
                    if model.trimVideoEnds {
                        Stepper(
                            "Cut \(model.trimHeadTailSeconds, specifier: "%.1f")s from start and end",
                            value: $model.trimHeadTailSeconds,
                            in: 0.1...30,
                            step: 0.5
                        )
                    }
                } header: {
                    Text("Trim")
                } footer: {
                    Text("Removes the same duration from the beginning and end before blending.")
                }

                Section {
                    Toggle(isOn: $model.linearLight) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("True-light blending")
                            Text("Blends in linear light — smoother highlights")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Blending")
                }
            }
            .navigationTitle("Advanced")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}

// MARK: - Custom speed sheet

struct CustomSpeedSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Speed: \(model.constantWindow)×", value: customSpeed, in: SpeedMath.range)
                    Slider(
                        value: Binding(
                            get: { Double(model.constantWindow) },
                            set: { customSpeed.wrappedValue = Int($0.rounded()) }
                        ),
                        in: Double(SpeedMath.range.lowerBound)...Double(SpeedMath.range.upperBound),
                        step: 1
                    )
                } footer: {
                    Text("\(model.constantWindow) real frames become one output frame\(estimateSuffix).")
                }
            }
            .navigationTitle("Custom speed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private var customSpeed: Binding<Int> {
        Binding {
            model.constantWindow
        } set: { newValue in
            model.useRamp = false
            model.constantWindow = newValue
        }
    }

    private var estimateSuffix: String {
        guard let seconds = model.estimatedOutputSeconds(speed: model.constantWindow) else { return "" }
        return " — about \(SpeedMath.clipLength(seconds))"
    }
}
