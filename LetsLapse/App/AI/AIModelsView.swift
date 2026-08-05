import SwiftUI

/// Settings › AI Models — the on-device model library.
///
/// The screen exists because the feature it powers is otherwise invisible: a multi-gigabyte
/// download is a decision, so it is presented as one, with the size, the quantization and the
/// on-device promise all on screen before the button is tapped.
struct AIModelsView: View {
    @ObservedObject private var manager = ModelManager.shared
    @State private var pendingDelete: CatalogModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.bottom, 4)

                if let catalogError = manager.catalogError {
                    Text(catalogError)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }

                if !manager.downloadedModels.isEmpty {
                    // Not "Downloaded" any more: the built-in row sits in this list and was never
                    // downloaded. The section is what you can pick, not what you fetched.
                    LLSectionHeader("On this device")
                    downloadedCard
                        .padding(.bottom, 12)
                }

                if !manager.availableModels.isEmpty {
                    LLSectionHeader("Available")
                    availableCard
                }

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(LL.screenBackground)
        .navigationTitle("AI Models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            manager.refreshStates()
            await manager.refreshDiskUsage()
        }
        .alert(item: $pendingDelete) { model in
            Alert(
                title: Text("Delete “\(model.name)”?"),
                message: Text("Frees \(sizeLabel(for: model)). You can download it again at any time."),
                primaryButton: .destructive(Text("Delete")) { manager.delete(model) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Vision tags your captures with no download. Add a language model to have them named too. Either way, nothing leaves this device.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12, weight: .semibold))
                Text(manager.totalDiskUsed > 0
                        ? "\(LLFormat.bytes(manager.totalDiskUsed)) used"
                        : "No models downloaded")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(manager.totalDiskUsed > 0 ? LL.accent : Color.secondary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Downloaded

    private var downloadedCard: some View {
        VStack(spacing: 0) {
            let models = manager.downloadedModels
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                let row = Button {
                    manager.activeModelID = model.id
                } label: {
                    installedRow(model, showsDivider: index != models.count - 1)
                }
                .buttonStyle(.plain)

                // A built-in can't be deleted, so it gets neither affordance — a swipe that
                // reveals a Delete which then refuses is worse than no swipe.
                if model.isBuiltIn {
                    row
                } else {
                    row
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = model
                            } label: {
                                Label("Delete model", systemImage: "trash")
                            }
                        }
                        .swipeToDelete {
                            pendingDelete = model
                        }
                }
            }
        }
        .llCard()
    }

    /// One pickable row. Hand-built rather than `LLRow` only because the title line carries a
    /// badge; the metrics below are `LLRow`'s, so the two stack without a seam.
    @ViewBuilder
    private func installedRow(_ model: CatalogModel, showsDivider: Bool) -> some View {
        let isActive = manager.activeModelID == model.id

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 16))
                        badge(for: model)
                    }
                    Text(model.isBuiltIn
                            ? "Built-in · always available"
                            : "\(model.quantization) · \(sizeLabel(for: model))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    if isActive {
                        Text("Active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LL.accent)
                    }
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(isActive ? LL.accent : Color.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if showsDivider {
                Divider().padding(.leading, 16)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Available

    private var availableCard: some View {
        VStack(spacing: 0) {
            let models = manager.availableModels
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                availableRow(model, showsDivider: index != models.count - 1)
            }
        }
        .llCard()
    }

    @ViewBuilder
    private func availableRow(_ model: CatalogModel, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 16))
                        badge(for: model)
                    }
                    Text("\(model.quantization) · \(LLFormat.bytes(model.approxDownloadBytes)) download")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text(model.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning = model.warning {
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LL.accentDeep)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                trailingControl(for: model)
            }

            if case .downloading(let progress, let status) = manager.state(of: model) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(LL.accent)
                    // The file count carries the reassurance the percentage can't: on a multi-shard
                    // model the bar sits still for minutes at a time even when nothing is wrong.
                    Text("\(status) · keep this screen open")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = manager.state(of: model) {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if showsDivider {
            Divider().padding(.leading, 16)
        }
    }

    @ViewBuilder
    private func trailingControl(for model: CatalogModel) -> some View {
        switch manager.state(of: model) {
        case .downloading:
            Button("Cancel") { manager.cancelDownload(of: model) }
                .buttonStyle(.bordered)
                .font(.system(size: 14))
        case .failed:
            Button("Retry") { manager.download(model) }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .font(.system(size: 14))
        default:
            Button("Download") { manager.download(model) }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .font(.system(size: 14))
        }
    }

    @ViewBuilder
    private func badge(for model: CatalogModel) -> some View {
        switch model.availability {
        case .recommended:
            badgeLabel("Recommended", color: LL.accent)
        case .experimental:
            badgeLabel("Experimental", color: .secondary)
        case .builtIn:
            // `accentDeep` rather than `amber`: the badge's own text sits on a 14%-opacity wash of
            // the same colour, and amber at that weight is unreadable on the light card.
            badgeLabel("Instant", color: LL.accentDeep)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    /// What the model actually occupies once installed, falling back to the catalog's figure until
    /// the folder walk lands.
    private func sizeLabel(for model: CatalogModel) -> String {
        LLFormat.bytes(manager.diskUsage[model.id] ?? model.approxDownloadBytes)
    }
}
