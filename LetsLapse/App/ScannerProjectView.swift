import SwiftUI
import LetsLapseKit

/// The project screen a **Scanner** shoot gets instead of the timelapse one.
///
/// The distinction is not cosmetic. Every other photo project in the app is
/// *material*: frames that exist to be averaged into something else, which is
/// why their screen leads with "New blended clip" and treats the originals as a
/// footnote. A Scanner set is the opposite — 36 individually composed poses,
/// each one framed by hand and fired when the scene settled, on their way to a
/// photogrammetry solver or a document pile. Blending them would destroy the
/// only thing they are for.
///
/// So the hierarchy inverts: the frames *are* the content (a browsable grid,
/// numbered, showing the rectified page where one has been written), export is
/// the primary action, and the blend path survives as one quiet secondary
/// button — because a set of 36 angles played back is a perfectly good thing to
/// want, just never the first thing.
struct ScannerProjectSections: View {
    @EnvironmentObject var model: AppModel
    let capture: AppModel.CaptureProject
    /// Hands the set back to the ordinary flow — the Adjust screen, a blend, a
    /// clip. Deliberately injected rather than called from here: this view does
    /// not own the flow, it just declines to lead with it.
    var onViewAsTimelapse: () -> Void

    /// The paper the corrector should snap to, read from the same setting the
    /// capture screen's PAPER row writes. A shoot doesn't record the stock it
    /// was shot on (the operator can change their mind afterwards, and often
    /// should), so the correction asks the same question the camera did.
    @AppStorage("letslapse.capture.scannerAspect")
    private var scannerAspectToken = PerspectiveAspect.auto.rawValue
    private var scannerAspect: PerspectiveAspect {
        PerspectiveAspect(rawValue: scannerAspectToken) ?? .auto
    }

    @State private var viewing: ScannerPose?
    @State private var export: ScannerExport?
    @State private var exportFailure: String?
    @State private var isExporting = false
    @State private var isCorrecting = false
    @State private var correctionNote: String?
    /// Bumped when a correction pass writes new files, so the poses reload and
    /// the grid swaps to the rectified pages.
    @State private var reloadToken = 0

    private struct ScannerExport: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    /// One pose: the frame the project counts, plus whichever file is the one
    /// worth looking at.
    private struct ScannerPose: Identifiable, Equatable {
        /// 1-based, matching the file names and what the operator counted out
        /// loud while shooting.
        let number: Int
        let viewable: URL
        let isCorrected: Bool
        let hasRectangle: Bool

        var id: Int { number }
    }

    @State private var poses: [ScannerPose] = []

    var body: some View {
        VStack(spacing: 14) {
            headerCard
            actions
            framesSection
        }
        .task(id: "\(capture.id)|\(capture.sourceFileNames.count)|\(reloadToken)") {
            poses = await loadPoses()
        }
        .alert(
            "Couldn't export frames",
            isPresented: Binding(
                get: { exportFailure != nil },
                set: { if !$0 { exportFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportFailure ?? "")
        }
        .sheet(item: $export) { export in
            ScannerExportSheet(folder: export.url, frameCount: poses.count)
        }
        #if os(iOS)
        .fullScreenCover(item: $viewing) { pose in
            ScannerFrameViewer(
                urls: poses.map(\.viewable),
                numbers: poses.map(\.number),
                start: pose.number)
        }
        #else
        .sheet(item: $viewing) { pose in
            ScannerFrameViewer(
                urls: poses.map(\.viewable),
                numbers: poses.map(\.number),
                start: pose.number)
                .frame(minWidth: 520, minHeight: 420)
        }
        #endif
    }

    // MARK: - Header

    /// What the set is, in the three facts that decide what can be done with
    /// it: how many poses were banked, when, and whether the detector had
    /// geometry — because "rectangle detection was on" is the difference
    /// between an export of rectified pages and an export of photographs of
    /// pages.
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .frame(width: 40, height: 40)
                    .background(LL.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(poseCountLine)
                        .font(.system(size: 17, weight: .bold))
                    Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: rectangleGlyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rectangleCount > 0 ? LL.accent : .secondary)
                Text(rectangleLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .llCard()
    }

    private var poseCountLine: String {
        let count = capture.sourceMediaCount
        return count == 1 ? "1 frame" : "\(count) frames"
    }

    private var rectangleGlyph: String {
        rectangleCount > 0 ? "doc.viewfinder.fill" : "square.dashed"
    }

    private var rectangleLine: String {
        guard rectangleCount > 0 else {
            return "No rectangle detected during this shoot"
        }
        let corrected = poses.filter(\.isCorrected).count
        let detected = "Rectangle detected on \(rectangleCount) of \(capture.sourceMediaCount) frames"
        if corrected == 0 { return detected + " · not yet corrected" }
        return detected + " · \(corrected) corrected"
    }

    /// How many poses recorded corners. Read from the sidecar, which is the
    /// record of what the camera saw at the moment each shutter was asked for —
    /// not from the files, which only say what has been *written* since.
    private var rectangleCount: Int {
        poses.filter(\.hasRectangle).count
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                exportFrames()
            } label: {
                if isExporting {
                    Label("Preparing…", systemImage: "square.and.arrow.up")
                } else {
                    Label("Export frames", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(LLPrimaryButtonStyle())
            .disabled(isExporting || poses.isEmpty)

            // The rectification the capture teardown deliberately doesn't run
            // (correcting a 36-pose set is seconds of GPU work and the paper
            // stock is the operator's call, not the camera's). This is the
            // "wherever the finished set is presented" the Scanner's own TODO
            // asks for, and it is what puts corrected pages in the export.
            // Only while there is something it could still do. The test is
            // "has corners and hasn't been rectified", not "isn't rectified":
            // a pose shot with nothing flat in view can never be corrected, so
            // the looser test would leave the button on screen for ever on any
            // set with one table-top frame in it.
            if poses.contains(where: { $0.hasRectangle && !$0.isCorrected }) {
                Button {
                    correctPerspective()
                } label: {
                    if isCorrecting {
                        Label("Correcting…", systemImage: "perspective")
                    } else {
                        Label("Correct perspective (\(scannerAspect.label))", systemImage: "perspective")
                    }
                }
                .buttonStyle(LLSecondaryButtonStyle())
                .disabled(isCorrecting)
            }

            Button {
                onViewAsTimelapse()
            } label: {
                Label("View as timelapse", systemImage: "play.rectangle")
            }
            .buttonStyle(LLSecondaryButtonStyle())

            if let correctionNote {
                Text(correctionNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Frames

    private var framesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Frames · \(poses.count)")
            if poses.isEmpty {
                Text("No frames on disk for this shoot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .llCard()
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                    spacing: 6
                ) {
                    ForEach(poses) { pose in
                        Button {
                            viewing = pose
                        } label: {
                            frameCell(pose)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func frameCell(_ pose: ScannerPose) -> some View {
        ProjectThumbnailView(url: pose.viewable, kind: .image)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                // The number is the pose's identity — it is what the sidecar,
                // the file name and the solver all call it — so it is on the
                // tile rather than a caption under it.
                Text("\(pose.number)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if pose.isCorrected {
                    Image(systemName: "perspective")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(LL.accent.opacity(0.85), in: Circle())
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
    }

    // MARK: - Loading

    /// Resolves each pose to the file worth showing. Off the main actor because
    /// it stats up to four candidates per frame and reads the sidecar; a
    /// 72-pose set would otherwise do that in a view body.
    private func loadPoses() async -> [ScannerPose] {
        let capture = capture
        let sidecar = model.scannerSidecar(for: capture)
        let withRectangles = Set(
            (sidecar?.entries ?? []).filter { $0.rectangle != nil }.map { $0.frame + 1 })
        var resolved: [ScannerPose] = []
        for number in 1...max(capture.sourceMediaCount, 1) where capture.sourceMediaCount > 0 {
            guard let viewable = model.scannerViewableURL(for: capture, frameNumber: number) else {
                continue
            }
            resolved.append(ScannerPose(
                number: number,
                viewable: viewable,
                isCorrected: model.scannerCorrectedURL(for: capture, frameNumber: number) != nil,
                hasRectangle: withRectangles.contains(number)))
        }
        return resolved
    }

    // MARK: - Export

    /// Builds the flat folder and hands it to the share sheet.
    ///
    /// Flat and sequentially named because that is what the other end wants: a
    /// solver, a scanner-app import, a folder someone will page through. The
    /// corrected page goes where there is one and the photograph where there
    /// isn't, so a set shot half against a page and half against the table
    /// still exports as one continuous run of numbers rather than with holes.
    private func exportFrames() {
        isExporting = true
        let poses = poses
        let name = capture.displayTitle
        Task {
            do {
                let folder = try await Task.detached(priority: .userInitiated) { () -> URL in
                    try ScannerFrameExport.buildFolder(
                        named: name,
                        files: poses.map { (number: $0.number, url: $0.viewable) })
                }.value
                isExporting = false
                export = ScannerExport(url: folder)
            } catch {
                isExporting = false
                exportFailure = error.localizedDescription
            }
        }
    }

    private func correctPerspective() {
        isCorrecting = true
        correctionNote = nil
        let folder = model.projectFolderURL(for: capture).appendingPathComponent("source")
        let aspect = scannerAspect
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PerspectiveCorrector.correctSequence(in: folder, aspect: aspect)
            }.value
            isCorrecting = false
            // No thumbnail invalidation needed: a correction writes NEW files,
            // so the grid's tiles change URL rather than content — and a tile
            // keyed on a URL nobody has decoded yet has nothing stale to drop.
            reloadToken += 1
            if result.written.isEmpty {
                correctionNote = result.failures.isEmpty
                    ? "Nothing to correct — no frame recorded a rectangle."
                    : "Couldn't correct any frame (\(result.failures.count) failed)."
            } else if result.failures.isEmpty {
                correctionNote = "Corrected \(result.written.count) frames."
            } else {
                correctionNote =
                    "Corrected \(result.written.count) frames · \(result.failures.count) couldn't be read."
            }
        }
    }
}

// MARK: - Export folder

/// Copies a Scanner set into a flat, sequentially-named folder.
enum ScannerFrameExport {

    /// `<name>/frame-0001.heic …`, renumbered from 1 in the order given, each
    /// file keeping its own extension.
    ///
    /// The numbering is **re-derived**, not carried: a set with a deleted pose
    /// has a gap in its capture indices, and an export with a gap in it reads
    /// as a missing frame to everything downstream. What the folder promises is
    /// "these, in this order".
    static func buildFolder(named name: String, files: [(number: Int, url: URL)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-export-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(safeFolderName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, file) in files.enumerated() {
            let ext = file.url.pathExtension.isEmpty ? "heic" : file.url.pathExtension
            let destination = folder.appendingPathComponent(
                String(format: "frame-%04d.%@", index + 1, ext))
            try FileManager.default.copyItem(at: file.url, to: destination)
        }
        return folder
    }

    /// A folder name a file system will take: the project's title with the
    /// separators knocked out, and never empty.
    static func safeFolderName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Scanner frames" : cleaned
    }
}

/// What comes back from "Export frames": the folder, its size, and the one
/// control that gets it off the device.
private struct ScannerExportSheet: View {
    let folder: URL
    let frameCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(folder.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("\(frameCount) frames, numbered from 1")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            #if os(iOS)
            ShareLink(item: folder) {
                Label("Share folder", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #else
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #endif
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 340)
        #endif
    }
}

// MARK: - Fullscreen frame

/// One pose, full screen, with the rest of the set a swipe away.
///
/// A deliberately thinner viewer than the interval browser's: there is no
/// per-frame Save here because a Scanner set is exported as a set — one frame
/// on its own is half a measurement — and no colour grade, because these files
/// are records rather than pictures.
private struct ScannerFrameViewer: View {
    let urls: [URL]
    let numbers: [Int]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(urls: [URL], numbers: [Int], start: Int) {
        self.urls = urls
        self.numbers = numbers
        _selection = State(initialValue: numbers.firstIndex(of: start) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
            }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    @ViewBuilder private var pager: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                ProjectPreviewImage(url: url, background: AnyShapeStyle(Color.black))
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        if urls.indices.contains(selection) {
            ProjectPreviewImage(url: urls[selection], background: AnyShapeStyle(Color.black))
                .overlay(alignment: .bottom) { macStepper }
        }
        #endif
    }

    #if os(macOS)
    private var macStepper: some View {
        HStack(spacing: 14) {
            Button("Previous") { selection = max(selection - 1, 0) }
                .disabled(selection == 0)
            Button("Next") { selection = min(selection + 1, urls.count - 1) }
                .disabled(selection >= urls.count - 1)
        }
        .padding(.bottom, 18)
    }
    #endif

    private var topBar: some View {
        HStack {
            Button("Done") { dismiss() }
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            Spacer()
            Text("Frame \(numbers.indices.contains(selection) ? numbers[selection] : selection + 1) of \(urls.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.35))
    }
}
