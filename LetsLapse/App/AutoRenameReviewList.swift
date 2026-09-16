import SwiftUI
import LetsLapseKit

// MARK: - The review list

/// The Gallery's grid, replaced in place by one row per selected project while Auto rename &
/// tag's suggestions are reviewed (2026-09-16, macOS/gallery.batch.autorename.svg). Not a sheet,
/// not a window: the selection header stays over it and the pane beside it becomes the panel
/// (`AutoRenameReviewPanel`).
///
/// A row is one project — its tile, the suggested name in a field, the suggested tags as pills, the
/// capture's own place and light as read-only chips, and Accept / Discard top right. Rows appear
/// at once, pending, and fill in as their analysis lands; a pending row's Accept is disabled and
/// its Discard is live. The tags wear no fractions and no partial styling: the batch panel's `2/3`
/// means "on 2 of the 3 selected", which has no meaning on a row about one project.
struct AutoRenameReviewList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: AutoRenameReviewSession
    /// A narrow column — the phone, a squeezed window: the tile narrows and the rest reflows.
    var compact = false

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(session.rows) { row in
                    let isFirst = session.rows.first?.id == row.id
                    AutoRenameReviewRow(
                        row: row,
                        name: session.nameBinding(row.id),
                        tags: session.tagsBinding(row.id),
                        capture: model.capture(id: row.id),
                        showsFactsHint: isFirst,
                        compact: compact,
                        onAccept: { session.accept(row.id) },
                        onDiscard: { session.discard(row.id) },
                        onRetry: { session.retry(row.id) })
                        .padding(.top, isFirst ? 10 : 14)
                        .padding(.bottom, 18)
                        .padding(.horizontal, compact ? 16 : 20)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
                    Divider()
                        .padding(.horizontal, compact ? 16 : 20)
                }
                Color.clear.frame(height: 82) // floating tab bar clearance
            }
        }
        .background(LL.screenBackground)
        .onAppear { adoptUndoManager() }
        .onChange(of: undoManager == nil) { _, _ in adoptUndoManager() }
        // A project that leaves the library — deleted here or from another tab — drops its row.
        .onChange(of: model.indexRevision) { _, _ in session.dropDeleted() }
        .accessibilityLabel("Auto rename & tag review, \(session.total) projects")
    }

    private func adoptUndoManager() {
        session.undoManager = undoManager
        #if DEBUG && os(macOS)
        let window = NSApp.keyWindow ?? NSApp.windows.first
        LLog("[autorename] undo manager env=\(undoManager.map { "\(ObjectIdentifier($0))" } ?? "nil") window=\(window?.undoManager.map { "\(ObjectIdentifier($0))" } ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        #endif
    }
}

// MARK: - One row

struct AutoRenameReviewRow: View {
    @EnvironmentObject var model: AppModel
    var row: AutoRenameReviewSession.Row
    /// By project id, not by index — see `AutoRenameReviewSession.nameBinding`.
    var name: Binding<String>
    var tags: Binding<[String]>
    var capture: AppModel.CaptureProject?
    /// "Read from location and time, not the image" — once, on the first row.
    var showsFactsHint: Bool
    var compact: Bool
    var onAccept: () -> Void
    var onDiscard: () -> Void
    var onRetry: () -> Void

    private var tileWidth: CGFloat { compact ? 132 : 230 }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 14 : 22) {
            if let capture {
                // The grid's own tile, ring and circle and badges included, so the row reads as
                // the selected tile it stands for. Inert here: nothing to open, nothing to toggle.
                GalleryTile(capture: capture, isSelected: true, showsCircle: true, onTap: {}, onOpen: {})
                    .frame(width: tileWidth)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                switch row.status {
                case .pending:
                    pendingBody
                case .failed(let message):
                    failedBody(message)
                case .ready, .accepted:
                    readyBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controls
        }
    }

    // MARK: Ready

    @ViewBuilder private var readyBody: some View {
        HStack(spacing: 8) {
            Text("Suggested name — edit it or leave it")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            // The project already carries a name a person chose: say so before Apply all
            // overwrites it. Clearing the field keeps it.
            if row.isNameUserSet, !row.name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Renaming")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LL.accentDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(LL.amber.opacity(0.35), in: Capsule())
                    .accessibilityLabel("Renaming a project you named yourself")
            }
        }
        .padding(.top, 4)

        TextField("Keep the existing name", text: name)
            .font(.system(size: 14, weight: .semibold))
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LL.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)))
            .frame(maxWidth: 358)
            .padding(.top, 8)
            .accessibilityLabel("Suggested name")

        rowHeader("Subject tags")
            .padding(.top, 16)
        TagField(tags: tags, libraryTags: model.libraryTags, style: .proposed)
            .padding(.top, 8)

        rowHeader("From this capture")
            .padding(.top, 16)
        factsRow
            .padding(.top, 8)
    }

    // MARK: Pending

    @ViewBuilder private var pendingBody: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Looking at this one…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)

        skeleton(width: 300, height: 32, radius: 6)
            .padding(.top, 8)
        HStack(spacing: 8) {
            skeleton(width: 90, height: 27, radius: 13.5)
            skeleton(width: compact ? 100 : 133, height: 27, radius: 13.5)
            if !compact { skeleton(width: 121, height: 27, radius: 13.5) }
        }
        .padding(.top, 23)
        factsRow
            .padding(.top, 20)
    }

    private func skeleton(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(maxWidth: width)
            .frame(height: height)
            .accessibilityHidden(true)
    }

    // MARK: Failed

    @ViewBuilder private func failedBody(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LL.levelOff)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Retry") { onRetry() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LL.accent)
        }
        .padding(.top, 4)
        factsRow
            .padding(.top, 20)
    }

    // MARK: Pieces

    /// The row's own section header — the spec's 11.5 pt, smaller than the panel's 13 pt
    /// `LLSectionHeader`: a row is a card inside a list, not a pane.
    private func rowHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }

    /// Place and light, read from the capture — not removable, not editable: facts, not
    /// suggestions. Populated before any analysis completes.
    @ViewBuilder private var factsRow: some View {
        HStack(spacing: 8) {
            if let place = row.facts?.place {
                factChip(place, systemImage: "mappin")
            }
            if let light = row.facts?.light {
                factChip(light.capitalized, systemImage: "sun.horizon")
            }
            if row.facts != nil, row.facts?.place == nil, row.facts?.light == nil {
                Text("No location or time on this capture")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            if showsFactsHint, row.facts != nil {
                Text("Read from location and time, not the image")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 25)
    }

    private func factChip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12.5))
        }
        .foregroundStyle(Color.primary.opacity(0.75))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(height: 25)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    /// Accept (the tick) and Discard (the cross). A pending row's Accept is disabled; Discard
    /// stays live and cancels that row's analysis. Both remove the row; the tick is the commit.
    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: onAccept) {
                circle(systemImage: "checkmark", fill: acceptFill)
            }
            .buttonStyle(.plain)
            .disabled(row.status != .ready)
            .accessibilityLabel(row.status == .accepted ? "Applied" : "Accept this row")

            Button(action: onDiscard) {
                circle(systemImage: "xmark", fill: LL.levelFar)
            }
            .buttonStyle(.plain)
            .disabled(row.status == .accepted)
            .accessibilityLabel("Discard this row")
        }
        .padding(.top, 1)
    }

    private var acceptFill: Color {
        switch row.status {
        case .ready, .accepted: return LL.levelGood
        case .pending, .failed: return Color.primary.opacity(0.18)
        }
    }

    private func circle(systemImage: String, fill: Color) -> some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
    }
}

// MARK: - The panel

/// The pane beside the review list on the wide layouts, and the bar under it on the compact one:
/// the count, what the rows mean, Cancel and Apply all, and the readiness line.
struct AutoRenameReviewPanel: View {
    @ObservedObject var session: AutoRenameReviewSession
    /// True for the compact layout's bottom bar: one row, no title.
    var asBar = false

    var body: some View {
        if asBar {
            bar
        } else {
            pane
        }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.total) projects")
                    .font(.system(size: 16, weight: .bold))
                Text("Names and tags below apply only to the row they sit on.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)
            .padding(.horizontal, 14)

            Divider()
                .padding(.top, 16)

            HStack(spacing: 14) {
                cancelButton
                applyButton
            }
            .padding(.top, 24)
            .padding(.horizontal, 14)

            Text(session.readinessLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34)
                .padding(.horizontal, 14)
                .accessibilityLabel(session.readinessLine)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LL.cardBackground)
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.readinessLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                cancelButton
                applyButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(LL.cardBackground)
    }

    private var cancelButton: some View {
        Button {
            session.cancel()
        } label: {
            Text("Cancel")
                .font(.system(size: 13.5))
                .foregroundStyle(LL.accent)
                .frame(width: 128, height: 40)
                .background(
                    Capsule().strokeBorder(LL.accent, style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel — back to the gallery, nothing written")
    }

    private var applyButton: some View {
        Button {
            session.applyAll()
        } label: {
            HStack(spacing: 7) {
                Text("Apply all")
                    .font(.system(size: 13.5, weight: .semibold))
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .frame(width: 130, height: 40)
            .background(LL.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.readyCount == 0)
        .opacity(session.readyCount == 0 ? 0.45 : 1)
        .accessibilityLabel("Apply all \(session.readyCount) ready rows")
    }
}
