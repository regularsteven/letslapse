import SwiftUI
import LetsLapseKit

/// One scan, opened: what it is, what state its correction is in, and its
/// pages — nothing else.
///
/// The grid runs to the bottom edge with nothing floating over it, so export
/// lives in the bar rather than on a pinned button, and the one thing that
/// does get a card is the correction prompt: an `LL.ink` strip with amber on
/// it, which is where amber genuinely belongs. It retires for good once every
/// page that *can* be corrected has been.
struct ScanDetailView: View {
    @EnvironmentObject var model: AppModel
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var session: ScanSession?
    @State private var reloadToken = 0
    @State private var isSelecting = false
    @State private var selection: Set<Int> = []
    @State private var viewingPage: ScanPage?
    @State private var recorrecting: ScanRecorrectRequest?
    @State private var isExporting = false
    @State private var correctionNote: String?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var pagePendingDelete: ScanPage?
    /// The document whose header's pencil was tapped, and the field behind it.
    @State private var renamingDocument: ScanDocument?
    @State private var documentNameText = ""
    /// "Share project": the whole capture folder as one importable `.lapse`.
    /// A scan archives through exactly the same path a shoot does — see
    /// `AppModel.exportProject` and `App/ProjectArchiveShare.swift`.
    /// Read off the model, not held here — see `ProjectDetailView`: an export
    /// has to be visible to the transfer server, and view-local state isn't.
    private var isExportingArchive: Bool {
        guard let capture else { return false }
        return model.activeLibraryActivities.contains(.exportingArchive(capture.id))
    }
    @State private var exportedArchive: ExportedArchive?
    @State private var exportFailure: String?
    @State private var confirmingDelete = false
    @State private var deletionFailure: String?

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == sessionID }
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                Color.clear
            }
        }
        .background(LL.screenBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(session?.detailTitle ?? "Scan")
        #endif
        .task(id: "\(sessionID)|\(reloadToken)") {
            await reload()
            #if DEBUG
            // `LL_SCANS_EXPORT` opens the export sheet, which no headless run
            // can otherwise reach — it is behind a tap on a toolbar button.
            // Raised after the load rather than on appear, because the sheet
            // draws nothing until the session it describes has resolved.
            // `=run` goes one further and presses every row, reporting the file
            // tree each one produced (`ScanExport.debugRun`).
            if let hook = ProcessInfo.processInfo.environment["LL_SCANS_EXPORT"],
               let session {
                if hook == "run" {
                    let groups = session.documentSections.map {
                        ScanExportGroup(name: $0.document.name, pages: $0.pages.map(\.viewable))
                    }
                    let paper = session.paper
                    Task.detached(priority: .utility) {
                        LLog(ScanExport.debugRun(named: "Scan", groups: groups, paper: paper))
                    }
                } else {
                    isExporting = true
                }
            }
            #endif
        }
        // Each corrected page is a new file for a tile that is already on
        // screen, so the set is re-walked per page rather than once at the
        // end — the grid rectifies itself in front of the operator.
        .onChange(of: model.scanCorrections[sessionID]) { _ in reloadToken += 1 }
        // Grouping lives in a sidecar rather than in the model, so the only
        // thing to observe is that it moved.
        .onChange(of: model.scanDocumentsToken) { _ in reloadToken += 1 }
        #if os(iOS)
        .fullScreenCover(item: $viewingPage) { page in
            pageViewer(startingAt: page)
        }
        #else
        .sheet(item: $viewingPage) { page in
            pageViewer(startingAt: page)
                .frame(minWidth: 560, minHeight: 520)
        }
        #endif
        .sheet(item: $recorrecting) { request in
            ScanRecorrectSheet(request: request) { outcome in
                apply(outcome)
            }
        }
        // No noun, here or on the menu item that raises it: a dialog opened from
        // inside one scan is already saying which one it renames. The delete
        // confirmation below keeps its noun, because that one is destructive and
        // this screen can also ask about a single *page*.
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let capture { model.renameProject(capture, to: renameText) }
                reloadToken += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to go back to the date.")
        }
        .alert(
            "Rename document",
            isPresented: Binding(
                get: { renamingDocument != nil },
                set: { if !$0 { renamingDocument = nil } })
        ) {
            TextField("Name", text: $documentNameText)
            Button("Save") {
                if let document = renamingDocument {
                    model.renameDocument(
                        document.id, in: sessionID, name: documentNameText)
                }
                renamingDocument = nil
            }
            Button("Cancel", role: .cancel) { renamingDocument = nil }
        } message: {
            Text("Leave it empty to go back to the numbered name.")
        }
        .alert(item: $pagePendingDelete) { page in
            Alert(
                title: Text("Delete page \(page.number)?"),
                message: Text("The photograph and its corrected copy are removed. "
                              + "The other pages keep their numbers."),
                primaryButton: .destructive(Text("Delete")) { deletePage(page) },
                secondaryButton: .cancel())
        }
        .alert("Delete scan?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteSessionMessage)
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deletionFailure != nil },
                set: { if !$0 { deletionFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionFailure ?? "")
        }
        .alert(
            "Couldn't share project",
            isPresented: Binding(
                get: { exportFailure != nil },
                set: { if !$0 { exportFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportFailure ?? "")
        }
        .exportedArchiveSheet($exportedArchive)
        .sheet(isPresented: $isExporting) {
            if let session {
                ScanExportSheet(
                    session: session,
                    selection: isSelecting && !selection.isEmpty ? selection : nil,
                    onSelectPages: {
                        isSelecting = true
                        if selection.isEmpty { selection = [] }
                    },
                    onViewAsTimelapse: {
                        // The one route back to the timelapse screen. Scans are
                        // excluded from the Projects list, but the project is
                        // still there — this pushes its detail, which routes to
                        // `ScannerProjectSections` exactly as it always did.
                        model.requestedProjectDetailID = sessionID
                    })
                    #if os(iOS)
                    // Also declared inside the sheet, and repeated here because
                    // the presentation site is the placement SwiftUI honours
                    // reliably — without it the system's own material shows
                    // around the action-sheet stack.
                    .presentationBackground(.clear)
                    #endif
            }
        }
    }

    // MARK: - Layout

    private func content(_ session: ScanSession) -> some View {
        VStack(spacing: 0) {
            if isSelecting {
                selectionBar(session)
            } else {
                navigationBar
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !isSelecting {
                        header(session)
                        // Only what the automatic pass could not do. While it
                        // is running there is nothing to prompt for, and the
                        // header is already saying so.
                        if model.scanCorrections[sessionID] == nil,
                           !session.correctablePages.isEmpty {
                            correctionStrip(session)
                                .padding(.top, 20)
                        }
                        if let correctionNote {
                            Text(correctionNote)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        }
                        // One document is drawn as the flat grid it has always
                        // been: a lone "Document 1" header over every page of a
                        // session that was never grouped is a distinction the
                        // operator did not make.
                        if !session.hasDocumentGroups {
                            LLSectionHeader("Pages · \(session.pageCount)")
                                .padding(.top, 22)
                                .padding(.bottom, 6)
                        }
                    }
                    if session.hasDocumentGroups {
                        documentSections(session)
                    } else {
                        pageGrid(session, pages: session.pages)
                    }
                    Color.clear.frame(height: isSelecting ? 190 : 82)
                }
                .padding(.horizontal, 16)
            }
        }
        .overlay(alignment: .bottom) {
            if isSelecting { exportSelectionBar }
        }
    }

    /// Drawn rather than native, because the selecting state replaces the whole
    /// bar (Done · "3 selected" · All) and the two have to be the same shape.
    ///
    /// The same three parts a shoot's bar has — back, the name centred, one
    /// `ellipsis.circle` — so that opening a scan and opening a video, photo or
    /// interval project are the same screen with different contents. That is
    /// also why the name is *here* rather than 28pt inside the scroll: the title
    /// of the thing you opened belongs in one place across the app.
    private var navigationBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Scans")
                        .font(.system(size: 17))
                }
                .foregroundStyle(LL.accent)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            sessionMenu
        }
        // Centred on the bar, not between the controls: an overlay so a long
        // name is centred the way a native title is, and inset past both sides
        // so it truncates rather than running under them.
        .overlay {
            Text(session?.detailTitle ?? "")
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 78)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// Everything that acts on the whole scan, in one menu — the two controls
    /// that used to sit in this bar included.
    ///
    /// Export and Share project are genuinely different exports and are drawn as
    /// such: Export is the *pages* (PDF, images, a selection), Share project is
    /// the whole capture folder as one `.lapse` — photographs, rectified copies,
    /// grouping and paper stock — for importing into another LetsLapse.
    private var sessionMenu: some View {
        Menu {
            Button {
                renameText = session?.name ?? ""
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                selection = []
                isSelecting = true
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            .disabled(hasNoPages)
            Button {
                isExporting = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(hasNoPages)
            Button {
                exportArchive()
            } label: {
                Label("Share project", systemImage: "shippingbox")
            }
            .disabled(isExportingArchive)
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        } label: {
            if isExportingArchive {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(LL.accent)
                    .contentShape(Rectangle().inset(by: -10))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Scan options")
    }

    private var hasNoPages: Bool {
        session?.pages.isEmpty ?? true
    }

    private func selectionBar(_ session: ScanSession) -> some View {
        HStack(spacing: 0) {
            Button("Done") {
                isSelecting = false
                selection = []
            }
            .font(.system(size: 17))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text(selection.isEmpty ? "Select pages" : "\(selection.count) selected")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Button(selection.count == session.pageCount ? "None" : "All") {
                selection = selection.count == session.pageCount
                    ? []
                    : Set(session.pages.map(\.number))
            }
            .font(.system(size: 17))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    /// What the scan *is*, with no title of its own: the name went to the bar
    /// when this screen picked up a shoot's shape, so the header opens on the
    /// facts — pages, stock, duration — and the correction state under them.
    ///
    /// Nothing was lost with the 28pt line. `subtitleLine` already carries the
    /// date whenever a name has taken the title, precisely so the date survives
    /// being replaced, and renaming moved to the menu the bar now holds.
    private func header(_ session: ScanSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.subtitleLine)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            HStack(spacing: 7) {
                // While the automatic pass is running the header IS the
                // progress: a scan lands here the instant its run ends, with a
                // minute of GPU work still to do, and a static "34 pages" over
                // keystoned thumbnails reads as a finished set that came out
                // wrong. The ring fills from the pass, not from the files,
                // because the files arrive one at a time behind it.
                if let correction = model.scanCorrections[sessionID] {
                    ScanCorrectionRing(
                        progress: correction.total > 0
                            ? Double(correction.completed) / Double(correction.total) : 0,
                        lineWidth: 3.4)
                        .frame(width: 13, height: 13)
                    Text(correction.line)
                        .font(.system(size: 13))
                        .foregroundStyle(LL.accent)
                } else {
                    if session.detectedCount > 0 {
                        ScanCorrectionRing(progress: session.correctionProgress, lineWidth: 3.4)
                            .frame(width: 13, height: 13)
                    }
                    Text(session.correctionLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 5)
            .animation(.easeInOut(duration: 0.2), value: model.scanCorrections[sessionID])
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only while some page has corners and no correction — and it says what
    /// the correction costs, which is nothing: the photographs stay.
    private func correctionStrip(_ session: ScanSession) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "perspective")
                .font(.system(size: 20))
                .foregroundStyle(LL.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(uncorrectedLine(session))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Originals are kept either way")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            Button {
                correctAll(session)
            } label: {
                Text(model.scanCorrections[sessionID] != nil ? "Correcting…" : "Correct")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(LL.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(LL.amber, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.scanCorrections[sessionID] != nil)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// What the automatic pass left behind — a page whose file could not be
    /// read, or one corrected before the orientation fix and re-offered. A
    /// fresh scan does not see this at all: by the time the screen opens, its
    /// correction is already running.
    private func uncorrectedLine(_ session: ScanSession) -> String {
        let count = session.correctablePages.count
        return count == 1 ? "One page not corrected" : "\(count) pages not corrected"
    }

    // MARK: - Pages

    /// The grouped layout: one titled section per document, each holding the
    /// same tiles the flat grid draws.
    ///
    /// Sections are drawn even while selecting — a selection that crosses two
    /// documents is a legitimate thing to export, and hiding the boundaries
    /// while choosing would be hiding exactly the fact that makes the choice
    /// mean something.
    private func documentSections(_ session: ScanSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.documentSections.enumerated()), id: \.element.id) { index, section in
                documentHeader(section)
                    .padding(.top, index == 0 && isSelecting ? 4 : 18)
                    .padding(.bottom, 6)
                pageGrid(session, pages: section.pages)
            }
        }
    }

    private func documentHeader(_ section: ScanDocumentSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.document.name)
                .font(.system(size: 17, weight: .semibold))
            Text(section.document.pageCountLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button {
                documentNameText = section.document.name
                renamingDocument = section.document
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(section.document.name)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        // The undo for a grouping nobody meant — a sitting shot with "new scan
        // = new doc" left on when it should have been off comes out as N
        // one-page documents, and re-filing them one page at a time would be
        // absurd. It only takes the sections away; no page moves and no file
        // is touched.
        .contextMenu {
            Button {
                documentNameText = section.document.name
                renamingDocument = section.document
            } label: {
                Label("Rename \(section.document.name)", systemImage: "pencil")
            }
            Button {
                model.flattenDocuments(in: sessionID)
            } label: {
                Label("Merge into one document", systemImage: "arrow.triangle.merge")
            }
        }
    }

    private func pageGrid(_ session: ScanSession, pages: [ScanPage]) -> some View {
        GeometryReader { proxy in
            let columns = Self.columnCount(for: proxy.size.width)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
                spacing: 6
            ) {
                ForEach(pages) { page in
                    Button {
                        if isSelecting {
                            toggle(page)
                        } else {
                            viewingPage = page
                        }
                    } label: {
                        ScanPageTile(
                            page: page,
                            aspectRatio: session.pageAspectRatio,
                            isSelecting: isSelecting,
                            isSelected: selection.contains(page.number))
                    }
                    .buttonStyle(.plain)
                    // Long-press for the one destructive thing a page can do.
                    // Not offered while selecting: that mode's whole subject is
                    // a set of pages, and a menu acting on one of them there
                    // would be acting on the wrong thing.
                    .contextMenu {
                        if !isSelecting {
                            movePageMenu(session, page: page)
                            Button(role: .destructive) {
                                pagePendingDelete = page
                            } label: {
                                Label("Delete page \(page.number)", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        // GeometryReader has no intrinsic height, so the grid's own height is
        // computed from the same numbers the layout uses.
        .frame(height: gridHeight(session, pageCount: pages.count))
    }

    /// Re-files one page. The capture screen's grouping is a guess made with
    /// hands full of paper, so the correction has to be available where the
    /// mistake is visible — on the page, in the section it landed in.
    @ViewBuilder
    private func movePageMenu(_ session: ScanSession, page: ScanPage) -> some View {
        let current = session.document(containing: page.number)
        Menu {
            ForEach(session.documents) { document in
                Button {
                    model.assignPage(page.number, toDocument: document.id, inSession: sessionID)
                } label: {
                    if document.id == current?.id {
                        Label(document.name, systemImage: "checkmark")
                    } else {
                        Text(document.name)
                    }
                }
                .disabled(document.id == current?.id)
            }
            Divider()
            Button {
                let document = model.addDocument(to: sessionID)
                model.assignPage(page.number, toDocument: document.id, inSession: sessionID)
            } label: {
                Label("New document", systemImage: "plus")
            }
        } label: {
            Label("Move page \(page.number) to…", systemImage: "doc.on.doc")
        }
    }

    /// 2-up on a phone, 3-up in landscape and on an iPad, 4 across a wide Mac
    /// window — the page is the unit, so the column count follows how many fit
    /// at a readable size rather than the device.
    static func columnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<600: return 2
        case ..<1000: return 3
        default: return 4
        }
    }

    private func gridHeight(_ session: ScanSession, pageCount: Int) -> CGFloat {
        guard pageCount > 0 else { return 0 }
        #if os(iOS)
        let width = UIScreen.main.bounds.width - 32
        #else
        let width: CGFloat = 361
        #endif
        let columns = Self.columnCount(for: width)
        let tileWidth = (width - CGFloat(columns - 1) * 6) / CGFloat(columns)
        let tileHeight = tileWidth / max(session.pageAspectRatio, 0.05)
        let rows = Int(ceil(Double(pageCount) / Double(columns)))
        return CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * 6
    }

    private var exportSelectionBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [LL.screenBackground.opacity(0), LL.screenBackground],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
            Button {
                isExporting = true
            } label: {
                Label(
                    selection.count == 1 ? "Export 1 page" : "Export \(selection.count) pages",
                    systemImage: "square.and.arrow.up")
            }
            .buttonStyle(LLPrimaryButtonStyle())
            .disabled(selection.isEmpty)
            .opacity(selection.isEmpty ? 0.5 : 1)
            .padding(.horizontal, 16)
            // Clear of the floating tab bar, which is drawn over every tab's
            // content: at the design's own 8pt the export button sits behind
            // it and tints the pill orange through its material.
            .padding(.bottom, Self.tabBarClearance)
            .background(LL.screenBackground)
        }
    }

    /// The pill's 58pt plus its 6pt inset, and a gap.
    private static var tabBarClearance: CGFloat {
        #if os(iOS)
        72
        #else
        78
        #endif
    }

    private func toggle(_ page: ScanPage) {
        if selection.contains(page.number) {
            selection.remove(page.number)
        } else {
            selection.insert(page.number)
        }
    }

    @ViewBuilder
    private func pageViewer(startingAt page: ScanPage) -> some View {
        if let session {
            ScanPageViewer(
                session: session,
                startPage: page.number,
                onRecorrect: { target in
                    recorrecting = ScanRecorrectRequest(
                        sessionID: sessionID, page: target, paper: session.paper)
                })
        }
    }

    // MARK: - Work

    private func reload() async {
        guard let capture else { return }
        let request = model.scanSessionRequest(for: capture)
        session = await Task.detached(priority: .userInitiated) {
            ScanSession.load(request)
        }.value
    }

    /// Rectifies every page that has corners and hasn't been done, in one pass,
    /// on the session's own stock. The per-page path — different corners, a
    /// different stock for one badly-shot sheet — is the viewer's
    /// "Re-correct…", which opens `ScanRecorrectSheet`.
    /// Throws one page away — a hand caught in frame, a sheet that came out
    /// unreadable. The remaining pages keep their numbers, deliberately: see
    /// `AppModel.deleteScanPage`.
    private func deletePage(_ page: ScanPage) {
        guard let capture else { return }
        model.deleteScanPage(page.number, from: capture)
        selection.remove(page.number)
        reloadToken += 1
    }

    /// Bundles the session into a portable `.lapse` and puts the share sheet up.
    ///
    /// Nothing scan-specific here on purpose: a scan's pages, its
    /// `frames.timestamps`, its `documents.json` grouping and its rectified
    /// copies all live inside the capture folder, and its paper stock rides in
    /// the manifest with the rest of the project — so the archive a shoot writes
    /// is already the archive a scan needs, and the import side puts it back in
    /// this tab from `captureMode`.
    private func exportArchive() {
        guard let capture else { return }
        model.beginActivity(.exportingArchive(capture.id))
        Task { @MainActor in
            defer { model.endActivity(.exportingArchive(capture.id)) }
            do {
                exportedArchive = ExportedArchive(url: try await model.exportProject(capture))
            } catch {
                exportFailure = error.localizedDescription
            }
        }
    }

    /// Throws the whole session away — every photograph, every rectified page.
    /// Dismisses on success, because the screen it leaves behind describes a
    /// project that no longer exists.
    private func deleteSession() {
        guard let capture else { return }
        do {
            try model.deleteCapture(capture)
            dismiss()
        } catch {
            deletionFailure = error.localizedDescription
        }
    }

    /// Counts what is actually at stake, corrected copies included — "8 pages"
    /// understates a set where six of them were also rectified.
    private var deleteSessionMessage: String {
        guard let session else {
            return "This permanently deletes the whole scan. There's no undo."
        }
        let pages = session.pageCount == 1 ? "1 page" : "\(session.pageCount) pages"
        let corrected = session.correctedCount > 0
            ? " and \(session.correctedCount == 1 ? "its corrected copy" : "their \(session.correctedCount) corrected copies")"
            : ""
        return "This permanently deletes all \(pages)\(corrected). There's no undo."
    }

    /// The manual re-run. Same pass the shoot already ran on its own — this is
    /// for the leftovers and for a set someone wants done again, so it goes
    /// through the model's runner and reports through the same header rather
    /// than growing a second progress story of its own.
    private func correctAll(_ session: ScanSession) {
        guard let capture else { return }
        correctionNote = nil
        model.runScanCorrection(
            capture, aspect: session.paper, total: session.correctablePages.count)
    }

    private func apply(_ outcome: ScanRecorrectOutcome) {
        switch outcome {
        case .replaced(let paper):
            // A page corrected on a stock the session doesn't claim would
            // otherwise leave the badge lying about what is on screen.
            if paper != .auto, session?.paper == .auto {
                model.setScannerPaper(paper, for: sessionID)
            }
            reloadToken += 1
        case .discarded:
            reloadToken += 1
        case .failed(let message):
            correctionNote = message
        }
    }
}

// MARK: - Page tile

/// One page: the rectified page where there is one, the photograph where there
/// isn't, its number, and — only when it has been corrected — the amber
/// `perspective` badge. Amber is legible here because it sits on imagery,
/// which is the token's job.
struct ScanPageTile: View {
    let page: ScanPage
    let aspectRatio: Double
    var isSelecting = false
    var isSelected = false

    var body: some View {
        ProjectThumbnailView(url: page.viewable, kind: .image)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .opacity(isSelecting && !isSelected ? 0.55 : 1)
            .overlay(alignment: .bottomLeading) {
                Text("\(page.number)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    selectionMark
                        .padding(7)
                } else if page.isCorrected {
                    Image(systemName: "perspective")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LL.ink)
                        .frame(width: 22, height: 22)
                        .background(LL.amber.opacity(0.92), in: Circle())
                        .padding(6)
                        .accessibilityLabel("Corrected")
                }
            }
            .overlay {
                if isSelecting && isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LL.accent, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Page \(page.number)\(page.isCorrected ? ", corrected" : "")")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var selectionMark: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(LL.accent, in: Circle())
        } else {
            Circle()
                .fill(.black.opacity(0.2))
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: 24, height: 24)
        }
    }
}
