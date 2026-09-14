import SwiftUI
import LetsLapseKit

/// Stage 4's conflict list (v2 plan §4.4): one row per project a person has
/// to decide — edited on both sides, deleted on one side and changed on the
/// other, or a twin with no base. Per row: keep this device's, keep
/// PicPlace's, keep both; at the top, the newest edit for all. Code-first
/// (D12); the mirror follows.
struct PicPlaceConflictsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var picplace: PicPlaceController
    @Environment(\.dismiss) private var dismiss
    @State private var busy: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PicPlace and this device disagree about \(picplace.conflicts.count) project\(picplace.conflicts.count == 1 ? "" : "s"). Choose which version stands, or keep both.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if let error = picplace.lastResolveError {
                        Text(error).font(.system(size: 12)).foregroundStyle(LL.levelOff)
                    }
                    Button {
                        Task { await picplace.resolveAllByNewest(); if picplace.conflicts.isEmpty { dismiss() } }
                    } label: {
                        Text("Use the most recent edit for all")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LL.accent)
                    .disabled(picplace.conflicts.isEmpty || !busy.isEmpty)

                    ForEach(picplace.conflicts) { conflict in
                        row(conflict)
                            .llCard()
                    }
                    if picplace.conflicts.isEmpty {
                        Text("Nothing to decide.").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(LL.screenBackground)
            .navigationTitle("Needs your decision")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private func row(_ conflict: PicPlaceController.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let localID = conflict.localID, let capture = model.capture(id: localID) {
                    ProjectThumbnailView(url: model.thumbnailURL(for: capture), kind: model.mediaKind(for: capture), cornerRadius: 6)
                        .frame(width: 64, height: 48)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(conflict.name).font(.system(size: 16, weight: .semibold))
                    Text(sides(conflict)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if busy.contains(conflict.id) { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                ForEach(options(conflict), id: \.label) { option in
                    Button(option.label) { run(conflict, option.resolution) }
                        .buttonStyle(.bordered)
                        .disabled(busy.contains(conflict.id))
                }
            }
        }
        .padding(12)
    }

    private struct Option { var label: String; var resolution: PicPlaceController.Resolution }

    private func options(_ conflict: PicPlaceController.Conflict) -> [Option] {
        switch conflict.kind {
        case .bothEdited, .unrelated:
            return [Option(label: "Keep this device's", resolution: .keepLocal),
                    Option(label: "Keep PicPlace's", resolution: .keepServer),
                    Option(label: "Keep both", resolution: .keepBoth)]
        case .deletedOnServer:
            return [Option(label: "Restore to PicPlace", resolution: .keepLocal),
                    Option(label: "Delete here too", resolution: .keepServer)]
        case .deletedHereEditedThere:
            return [Option(label: "Delete on PicPlace", resolution: .keepLocal),
                    Option(label: "Bring it back here", resolution: .keepServer)]
        }
    }

    private func sides(_ conflict: PicPlaceController.Conflict) -> String {
        let local = conflict.localEditedAt.map { "This device · edited \($0.formatted(date: .abbreviated, time: .shortened))" }
        let device = conflict.serverDevice.map { " · from \($0)" } ?? ""
        let server: String
        switch conflict.kind {
        case .deletedOnServer:
            server = "PicPlace · deleted \(conflict.serverEditedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")\(device)"
        case .deletedHereEditedThere:
            server = "Deleted here · PicPlace edited \(conflict.serverEditedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")\(device)"
        case .unrelated:
            server = "PicPlace · edited \(conflict.serverEditedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")\(device) · never agreed with this device"
        case .bothEdited:
            server = "PicPlace · edited \(conflict.serverEditedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")\(device)"
        }
        return [local, server].compactMap { $0 }.joined(separator: "\n")
    }

    private func run(_ conflict: PicPlaceController.Conflict, _ resolution: PicPlaceController.Resolution) {
        busy.insert(conflict.id)
        Task {
            await picplace.resolve(conflict, resolution)
            busy.remove(conflict.id)
            if picplace.conflicts.isEmpty { dismiss() }
        }
    }
}

private struct PicPlaceConflictsSheet: ViewModifier {
    @ObservedObject var picplace: PicPlaceController
    func body(content: Content) -> some View {
        content.sheet(isPresented: $picplace.isReviewingConflicts) {
            PicPlaceConflictsView(picplace: picplace)
        }
    }
}

extension View {
    func picplaceConflictsSheet(_ picplace: PicPlaceController) -> some View {
        modifier(PicPlaceConflictsSheet(picplace: picplace))
    }
}
