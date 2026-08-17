import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import LetsLapseKit

// MARK: - Formats

/// What leaves the device. Format is chosen *first*, in the sheet's header,
/// because it changes what every row below it means: HEIC and JPEG produce a
/// folder of pages, PDF produces a document (or a document per page).
enum ScanExportFormat: String, CaseIterable, Identifiable {
    case heic
    case jpeg
    case pdf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        case .pdf: return "PDF"
        }
    }

    /// The one line under the segment that says what the choice costs.
    func caption(paper: PerspectiveAspect) -> String {
        switch self {
        case .heic:
            return "As captured — no re-encode, smallest files"
        case .jpeg:
            return "Re-encoded at high quality — opens anywhere"
        case .pdf:
            return paper == .auto
                ? "One page per sheet at each page's own size, in capture order"
                : "One page per sheet at \(paper.label), in capture order"
        }
    }
}

// MARK: - Scope

/// What leaves: everything, some documents, or a hand-picked set of pages.
///
/// Only offered on a session that has more than one document — a flat scan has
/// one honest answer and a picker with one option is a question that isn't.
enum ScanExportScope: String, CaseIterable, Identifiable {
    case allDocuments
    case selectedDocuments
    case selectedPages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allDocuments: return "All"
        case .selectedDocuments: return "Documents"
        case .selectedPages: return "Pages"
        }
    }
}

/// One document's worth of an export: the name its folder or PDF takes, and the
/// files, already resolved to "the corrected page where there is one".
struct ScanExportGroup: Sendable {
    var name: String
    var pages: [URL]
}

// MARK: - Builders

/// Copies or re-encodes a set of pages into something shareable.
///
/// The numbering is **re-derived**, never carried: an export of a selection
/// numbered 1, 4, 7 reads downstream as a document with four pages missing.
/// What the folder promises is "these, in this order".
enum ScanExport {

    /// `<name>/page-001.heic …`, in the order given.
    static func buildFolder(
        named name: String, pages: [(number: Int, url: URL)], format: ScanExportFormat
    ) throws -> URL {
        let folder = try makeFolder(named: name)
        for (index, page) in pages.enumerated() {
            switch format {
            case .heic:
                // The page's own extension: a `.jpg` shot on the no-RAW
                // fallback copied as `.heic` would be a file that lies about
                // what is inside it.
                let ext = page.url.pathExtension.isEmpty ? "heic" : page.url.pathExtension
                try FileManager.default.copyItem(
                    at: page.url,
                    to: folder.appendingPathComponent(String(format: "page-%03d.%@", index + 1, ext)))
            case .jpeg:
                try writeJPEG(
                    from: page.url,
                    to: folder.appendingPathComponent(String(format: "page-%03d.jpg", index + 1)))
            case .pdf:
                try writePDF(
                    pages: [page.url],
                    paper: .auto,
                    to: folder.appendingPathComponent(String(format: "page-%03d.pdf", index + 1)))
            }
        }
        return folder
    }

    /// One document, one page per sheet.
    static func buildDocument(
        named name: String, pages: [URL], paper: PerspectiveAspect
    ) throws -> URL {
        let folder = try makeFolder(named: name)
        let file = folder.appendingPathComponent("\(safeName(name)).pdf")
        try writePDF(pages: pages, paper: paper, to: file)
        return file
    }

    // MARK: Grouped

    /// `<name>/Document 1/page-001.heic …` — a subfolder per document.
    ///
    /// A single group stays **flat** (`<name>/page-001.heic`), because a folder
    /// containing one folder is a step nobody wanted; this is the same output
    /// `buildFolder` always produced, which is what keeps the ungrouped scan's
    /// export byte-for-byte what it was.
    ///
    /// Page numbering restarts inside each document, for the reason the flat
    /// export renumbers at all: what a folder promises is "these, in this
    /// order", and a receipt that is page 7 of a sitting is page 1 of itself.
    static func buildGroupedFolder(
        named name: String, groups: [ScanExportGroup], format: ScanExportFormat
    ) throws -> URL {
        guard groups.count > 1 else {
            return try buildFolder(
                named: name,
                pages: (groups.first?.pages ?? []).enumerated()
                    .map { (number: $0.offset + 1, url: $0.element) },
                format: format)
        }
        let root = try makeFolder(named: name)
        for group in uniquelyNamed(groups) {
            let folder = root.appendingPathComponent(safeName(group.name), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, page) in group.pages.enumerated() {
                try writePage(page, to: folder, number: index + 1, format: format)
            }
        }
        return root
    }

    /// One PDF per document. A single group produces the one file
    /// `buildDocument` would have.
    static func buildDocumentsPerGroup(
        named name: String, groups: [ScanExportGroup], paper: PerspectiveAspect
    ) throws -> URL {
        guard groups.count > 1 else {
            return try buildDocument(
                named: groups.first?.name ?? name,
                pages: groups.first?.pages ?? [],
                paper: paper)
        }
        let root = try makeFolder(named: name)
        for group in uniquelyNamed(groups) {
            try writePDF(
                pages: group.pages,
                paper: paper,
                to: root.appendingPathComponent("\(safeName(group.name)).pdf"))
        }
        return root
    }

    /// Every page of every document in one PDF, documents in order — for the
    /// person filing the whole sitting as a single thing.
    static func buildCombinedDocument(
        named name: String, groups: [ScanExportGroup], paper: PerspectiveAspect
    ) throws -> URL {
        try buildDocument(named: name, pages: groups.flatMap(\.pages), paper: paper)
    }

    private static func writePage(
        _ source: URL, to folder: URL, number: Int, format: ScanExportFormat
    ) throws {
        switch format {
        case .heic:
            let ext = source.pathExtension.isEmpty ? "heic" : source.pathExtension
            try FileManager.default.copyItem(
                at: source,
                to: folder.appendingPathComponent(String(format: "page-%03d.%@", number, ext)))
        case .jpeg:
            try writeJPEG(
                from: source,
                to: folder.appendingPathComponent(String(format: "page-%03d.jpg", number)))
        case .pdf:
            try writePDF(
                pages: [source],
                paper: .auto,
                to: folder.appendingPathComponent(String(format: "page-%03d.pdf", number)))
        }
    }

    /// Two documents both called "Invoices" are two folders with one name, and
    /// the second write would land inside the first. Renaming is a display
    /// concern the file system doesn't share, so it is settled here rather than
    /// forbidden in the rename field.
    private static func uniquelyNamed(_ groups: [ScanExportGroup]) -> [ScanExportGroup] {
        var seen: [String: Int] = [:]
        return groups.map { group in
            let key = safeName(group.name).lowercased()
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            var copy = group
            if count > 1 { copy.name = "\(group.name) (\(count))" }
            return copy
        }
    }

    // MARK: Bundling

    /// Zips a folder so an export arrives as one thing.
    ///
    /// A folder handed to the share sheet is a folder: some destinations take
    /// it, some take the first file in it, and some silently take nothing. A
    /// `.zip` is the one shape every one of them understands.
    ///
    /// `NSFileCoordinator`'s `.forUploading` is the zip writer both platforms
    /// already ship — no dependency, no `Process` (which doesn't exist on iOS),
    /// and it is the same call the system uses when you share a folder from
    /// Files.
    static func zip(_ folder: URL) throws -> URL {
        var coordinatorError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: folder, options: [.forUploading], error: &coordinatorError
        ) { temporary in
            let destination = folder.deletingLastPathComponent()
                .appendingPathComponent("\(folder.lastPathComponent).zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                // Moved, not copied: the coordinator's file lives only for the
                // duration of this block.
                try FileManager.default.moveItem(at: temporary, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        switch result {
        case .success(let url): return url
        case .failure(let error): throw error
        case nil: throw ScanExportError.writeFailed(folder)
        }
    }

    /// What actually goes to the share sheet: a lone file as itself, anything
    /// with structure as a zip. A one-page PDF should not arrive as an archive
    /// someone has to unpack to read it.
    static func package(_ url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return url }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
        // A folder holding exactly one file and nothing else is that file —
        // this is what a single-document PDF export lands as.
        if contents.count == 1 {
            var childIsDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: contents[0].path, isDirectory: &childIsDirectory)
            if !childIsDirectory.boolValue { return contents[0] }
        }
        return try zip(url)
    }

    /// What the export will weigh — **measured**, not guessed: one page is
    /// encoded to the chosen format, weighed, and multiplied by the page
    /// count.
    ///
    /// The guess it replaces (a multiplier on the source bytes) was out by
    /// 3.5× on a real PDF, because what a PDF does to an image has very little
    /// to do with what the source file weighed. One page's worth of work is a
    /// cheap price for a number that is true.
    static func estimatedBytes(
        pages: [URL], format: ScanExportFormat, paper: PerspectiveAspect = .auto
    ) -> Int64 {
        let sourceTotal = pages.reduce(Int64(0)) { $0 + bytes(of: $1) }
        guard format != .heic, let sample = pages.first else { return sourceTotal }
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-estimate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            switch format {
            case .jpeg: try writeJPEG(from: sample, to: probe)
            // The session's own stock, because the sheet a page lands on is
            // most of what a PDF page weighs.
            case .pdf: try writePDF(pages: [sample], paper: paper, to: probe)
            case .heic: return sourceTotal
            }
        } catch {
            return sourceTotal
        }
        // Scaled by the sample's share of the source bytes rather than by page
        // count alone, so a set with one much larger page isn't misreported.
        let sampleSource = max(bytes(of: sample), 1)
        return Int64(Double(bytes(of: probe)) * Double(sourceTotal) / Double(sampleSource))
    }

    private static func bytes(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }

    // MARK: Files

    private static func makeFolder(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-export-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(safeName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A name a file system will take, and never empty.
    static func safeName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Scan" : cleaned
    }

    private static func writeJPEG(from source: URL, to destination: URL) throws {
        guard let image = loadOriented(source) else {
            throw ScanExportError.unreadable(source)
        }
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScanExportError.writeFailed(destination)
        }
        CGImageDestinationAddImage(
            output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ScanExportError.writeFailed(destination)
        }
    }

    /// Lays each page on its own sheet, centred and aspect-fitted.
    ///
    /// A named stock gives every sheet the same size — which is the point of
    /// naming one — and the sheet turns landscape for a page that is wider
    /// than it is tall, because a page photographed on its side is the same
    /// stock rotated. `.auto` has no stock, so each sheet takes the page's own
    /// proportions at a 842pt long edge (A4's, as a sane upper bound).
    static func writePDF(pages: [URL], paper: PerspectiveAspect, to destination: URL) throws {
        guard let consumer = CGDataConsumer(url: destination as CFURL) else {
            throw ScanExportError.writeFailed(destination)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ScanExportError.writeFailed(destination)
        }
        for url in pages {
            guard let image = loadOriented(url) else { continue }
            var box = sheet(
                for: paper,
                imageSize: CGSize(width: image.width, height: image.height))
            context.beginPage(mediaBox: &box)
            context.draw(image, in: fit(
                CGSize(width: image.width, height: image.height), into: box))
            context.endPage()
        }
        context.closePDF()
    }

    /// The sheet a page lands on, in points.
    static func sheet(for paper: PerspectiveAspect, imageSize: CGSize) -> CGRect {
        let isLandscape = imageSize.width > imageSize.height
        let portrait: CGSize
        switch paper {
        case .a4: portrait = CGSize(width: 595.28, height: 841.89)
        case .letter: portrait = CGSize(width: 612, height: 792)
        // A 4×6 print, at 72 pt/inch.
        case .fourBySix: portrait = CGSize(width: 288, height: 432)
        case .square: portrait = CGSize(width: 612, height: 612)
        case .auto:
            guard imageSize.width > 0, imageSize.height > 0 else {
                return CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            }
            let scale = 841.89 / max(imageSize.width, imageSize.height)
            return CGRect(
                x: 0, y: 0,
                width: (imageSize.width * scale).rounded(),
                height: (imageSize.height * scale).rounded())
        }
        return CGRect(
            x: 0, y: 0,
            width: isLandscape ? portrait.height : portrait.width,
            height: isLandscape ? portrait.width : portrait.height)
    }

    private static func fit(_ size: CGSize, into box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: box.midX - fitted.width / 2,
            y: box.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height)
    }

    /// Decoded with its EXIF orientation applied — a page exported sideways is
    /// a page nobody can read.
    private static func loadOriented(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum ScanExportError: LocalizedError {
    case unreadable(URL)
    case writeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Couldn't read \(url.lastPathComponent)."
        case .writeFailed(let url): return "Couldn't write \(url.lastPathComponent)."
        }
    }
}

// MARK: - Sheet

/// The export sheet: what leaves, in what format, and — implicitly — as one
/// package.
///
/// Three decisions in the order they change each other. Scope first, because a
/// sitting of eleven receipts and a sitting of one contract want different
/// things and the rows below say different things for each. Format second,
/// because it decides whether the output is a folder of pages or a document.
/// Bundling is not a decision at all: anything with structure arrives as a zip,
/// anything that is one file arrives as that file (see `ScanExport.package`).
///
/// "Corrected page where there is one, the photograph where there isn't" is
/// the promise the whole tab rests on — a set shot half against a page and
/// half against a table still exports as one continuous run of numbers rather
/// than with holes in it.
struct ScanExportSheet: View {
    let session: ScanSession
    /// Page numbers when the screen is in selection mode, nil for the whole
    /// document.
    var selection: Set<Int>?
    var onSelectPages: () -> Void
    var onViewAsTimelapse: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var format: ScanExportFormat = .heic
    @State private var scope: ScanExportScope = .allDocuments
    /// Which documents the `.selectedDocuments` scope means. Seeded with all of
    /// them the first time that scope is chosen, so the row that appears is a
    /// list to *narrow* rather than an empty one to build — an export sheet
    /// that starts by exporting nothing has the wrong default.
    @State private var selectedDocuments: Set<UUID> = []
    @State private var isWorking = false
    @State private var result: ScanShareItem?
    @State private var failure: String?
    /// Measured off the main actor when the format changes; nil until the
    /// first measurement lands, and the row simply omits the size until then.
    @State private var estimate: Int64?

    /// Whether the scope picker is worth showing: a session with one document
    /// has one answer, and a screen that arrived here with pages already picked
    /// has made the choice already.
    private var offersScope: Bool { session.hasDocumentGroups && selection == nil }

    /// What will actually be written, as documents.
    ///
    /// One group is the flat export this sheet has always produced; several
    /// give per-document subfolders or a PDF each. A hand-picked page selection
    /// is deliberately **one** group whatever it spans: the operator picked
    /// those pages as a thing, and re-imposing the sitting's grouping on it
    /// would be answering a question they didn't ask.
    private var groups: [ScanExportGroup] {
        if let selection {
            let pages = session.pages.filter { selection.contains($0.number) }
            return [ScanExportGroup(name: documentName, pages: pages.map(\.viewable))]
        }
        guard session.hasDocumentGroups else {
            return [ScanExportGroup(name: documentName, pages: session.pages.map(\.viewable))]
        }
        let sections = session.documentSections.filter { section in
            scope == .selectedDocuments ? selectedDocuments.contains(section.id) : true
        }
        return sections.map {
            ScanExportGroup(name: $0.document.name, pages: $0.pages.map(\.viewable))
        }
    }

    private var files: [URL] { groups.flatMap(\.pages) }

    private var pageCount: Int { files.count }

    private var title: String {
        pageCount == 1 ? "Export 1 page" : "Export \(pageCount) pages"
    }

    private var documentName: String {
        session.name.map(ScanExport.safeName)
            ?? ("Scan " + session.createdAt.formatted(
                .dateTime.day().month(.abbreviated).hour().minute())
                .replacingOccurrences(of: ":", with: "."))
    }

    var body: some View {
        content
            .task(id: "\(format.rawValue)|\(pageCount)") {
                guard format == .pdf else { return }
                let sources = files
                let chosen = format
                let paper = session.paper
                estimate = await Task.detached(priority: .utility) {
                    ScanExport.estimatedBytes(pages: sources, format: chosen, paper: paper)
                }.value
            }
            #if os(iOS)
            // Sized to the rows so the stack sits where an action sheet would,
            // and clear so the two cards read as the sheet rather than as
            // cards inside one.
            .presentationDetents([.height(sheetHeight)])
            .presentationBackground(.clear)
            .presentationDragIndicator(.hidden)
            #endif
            .sheet(item: $result) { item in
                ScanShareSheet(urls: [item.url])
            }
            .alert(
                "Couldn't export",
                isPresented: Binding(
                    get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        // The sheet's own surface is the card. iOS 26 draws sheets on glass
        // and ignores `presentationBackground(.clear)`, so an action-sheet
        // stack floated inside one only shows the platform's material around
        // its edges — this is the same layout with the system's surface doing
        // the job the two cards were drawn to do.
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 8)
            Button("Cancel") { dismiss() }
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
        }
        #else
        VStack(spacing: 14) {
            card
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        #endif
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if offersScope, scope == .selectedDocuments {
                Divider()
                documentList
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Button {
                    row.action()
                } label: {
                    VStack(spacing: 5) {
                        Text(row.title)
                            .font(.system(size: 19, weight: row.isPrimary ? .semibold : .regular))
                            .foregroundStyle(row.isMuted ? Color.secondary : LL.accent)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: 12).monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, row.detail == nil ? 17 : 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || (row.needsPages && pageCount == 0))
                .opacity(row.needsPages && pageCount == 0 ? 0.45 : 1)
                if index < rows.count - 1 { Divider() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text(isWorking ? "Preparing…" : title)
                .font(.system(size: 13, weight: .semibold))
            Text("Corrected page where there is one, the photograph where there isn't. Originals stay on the device.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            if offersScope {
                Picker("Scope", selection: $scope) {
                    ForEach(ScanExportScope.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 9)
                .onChange(of: scope) { newValue in
                    switch newValue {
                    case .selectedDocuments:
                        if selectedDocuments.isEmpty {
                            selectedDocuments = Set(session.documents.map(\.id))
                        }
                    case .selectedPages:
                        // Page picking happens in the grid, not in a sheet
                        // covering it — so this scope is a door rather than a
                        // state, and it hands the screen back.
                        scope = .allDocuments
                        dismiss()
                        onSelectPages()
                    case .allDocuments:
                        break
                    }
                }
            }
            Picker("Format", selection: $format) {
                ForEach(ScanExportFormat.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 9)
            Text(formatCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// The format's own line, plus the one thing bundling needs to say: that
    /// what arrives is a single `.zip`. Said here rather than as a toggle,
    /// because there is no useful other answer — a share sheet handed a folder
    /// behaves differently in every destination.
    private var formatCaption: String {
        let base = format.caption(paper: session.paper)
        guard groups.count > 1 else { return base }
        return base + " · one folder per document, zipped"
    }

    /// The documents to include, when the scope is narrowing. Scrolls rather
    /// than growing the sheet without limit — a sitting can carry twenty
    /// receipts.
    private var documentList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(session.documentSections) { section in
                    Button {
                        if selectedDocuments.contains(section.id) {
                            selectedDocuments.remove(section.id)
                        } else {
                            selectedDocuments.insert(section.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedDocuments.contains(section.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(selectedDocuments.contains(section.id)
                                                 ? LL.accent : Color.secondary)
                            Text(section.document.name)
                                .font(.system(size: 15))
                            Spacer(minLength: 6)
                            Text(section.document.pageCountLine)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: documentListHeight)
    }

    private var documentListHeight: CGFloat {
        min(CGFloat(session.documents.count), 4) * 38
    }

    // MARK: Rows

    private struct Row {
        var title: String
        var detail: String?
        var isPrimary = true
        var isMuted = false
        /// Rows that write something, and are therefore meaningless with an
        /// empty scope (every document unticked).
        var needsPages = true
        var action: () -> Void
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let ext = format == .pdf ? "pdf" : (format == .jpeg ? "jpg" : "heic")
        let grouped = groups.count > 1
        let range = pageCount == 1
            ? String(format: "page-001.%@", ext)
            : String(format: "page-001.%@ … page-%03d.%@", ext, pageCount, ext)
        // With subfolders the numbering restarts in each, so a flat "page-001 …
        // page-011" would be describing a file layout that isn't there.
        let folderDetail = grouped
            ? "\(groups.count) folders · \(ScanExport.safeName(groups[0].name))/page-001.\(ext) …"
            : range

        if format == .pdf {
            if grouped {
                rows.append(Row(
                    title: "One PDF per document",
                    detail: "\(groups.count) PDFs"
                        + (estimate.map { " · ≈ \(LLFormat.bytes($0))" } ?? ""),
                    action: { exportPDFPerDocument() }))
                rows.append(Row(
                    title: "Combined PDF",
                    detail: "\(documentName).pdf · \(pageCount) pages",
                    isPrimary: false,
                    action: { exportCombinedPDF() }))
            } else {
                rows.append(Row(
                    title: pageCount == 1 ? "One PDF, 1 page" : "One PDF, \(pageCount) pages",
                    detail: "\(documentName).pdf"
                        + (estimate.map { " · ≈ \(LLFormat.bytes($0))" } ?? ""),
                    action: { exportCombinedPDF() }))
            }
            rows.append(Row(
                title: "One PDF per page",
                detail: folderDetail,
                isPrimary: false,
                action: { exportFolder() }))
        } else {
            rows.append(Row(
                title: exportRowTitle,
                detail: folderDetail,
                action: { exportFolder() }))
        }

        // The route into page picking. Kept for the flat session, where there
        // is no scope picker to carry it.
        if selection == nil, !offersScope {
            rows.append(Row(
                title: "Export selected pages…",
                isPrimary: false,
                needsPages: false,
                action: {
                    dismiss()
                    onSelectPages()
                }))
        }

        rows.append(Row(
            title: "View as timelapse",
            isPrimary: false,
            isMuted: true,
            needsPages: false,
            action: {
                dismiss()
                onViewAsTimelapse()
            }))
        return rows
    }

    private var exportRowTitle: String {
        if selection != nil { return "Export selected pages" }
        if groups.count > 1 { return "Export \(groups.count) documents" }
        return "Export all pages"
    }

    /// Header, the rows as they will actually be laid out, and the Cancel card
    /// — so the sheet is exactly as tall as what is in it whichever format is
    /// chosen.
    private var sheetHeight: CGFloat {
        let rowHeight = rows.reduce(CGFloat(0)) { $0 + ($1.detail == nil ? 55 : 73) }
        let scopeHeight: CGFloat = offersScope ? 41 : 0
        let listHeight: CGFloat = offersScope && scope == .selectedDocuments
            ? documentListHeight + 1
            : 0
        return 152 + scopeHeight + listHeight + rowHeight + 70
    }

    // MARK: Work

    private func exportFolder() {
        let chosen = format
        run { name, groups in
            try ScanExport.buildGroupedFolder(named: name, groups: groups, format: chosen)
        }
    }

    private func exportPDFPerDocument() {
        let paper = session.paper
        run { name, groups in
            try ScanExport.buildDocumentsPerGroup(named: name, groups: groups, paper: paper)
        }
    }

    private func exportCombinedPDF() {
        let paper = session.paper
        run { name, groups in
            try ScanExport.buildCombinedDocument(named: name, groups: groups, paper: paper)
        }
    }

    /// Builds off the main actor, then packages: one file goes as itself,
    /// anything else goes as a zip.
    private func run(_ build: @escaping (String, [ScanExportGroup]) throws -> URL) {
        guard !isWorking, pageCount > 0 else { return }
        isWorking = true
        let name = documentName
        let payload = groups
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do {
                    return .success(try ScanExport.package(try build(name, payload)))
                } catch {
                    return .failure(error)
                }
            }.value
            isWorking = false
            switch outcome {
            case .success(let url): result = ScanShareItem(url: url)
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}

#if DEBUG
// MARK: - Export harness

extension ScanExport {
    /// `LL_SCANS_EXPORT=run` — builds every shape the sheet can produce and
    /// reports the tree each one landed as.
    ///
    /// The sheet's rows are behind taps no headless run can make, and the two
    /// things most worth checking are exactly the two a screenshot cannot show:
    /// that a grouped export really lands as a subfolder per document with its
    /// numbering restarted, and that the zip step produces a readable archive
    /// on the device rather than on the Mac the writer was reasoned about.
    static func debugRun(
        named name: String, groups: [ScanExportGroup], paper: PerspectiveAspect
    ) -> String {
        var report = "🖼️LL export harness · \(groups.count) group(s), "
            + "\(groups.reduce(0) { $0 + $1.pages.count }) page(s)\n"
        let builds: [(String, () throws -> URL)] = [
            ("HEIC folders", { try buildGroupedFolder(named: name, groups: groups, format: .heic) }),
            ("JPEG folders", { try buildGroupedFolder(named: name, groups: groups, format: .jpeg) }),
            ("PDF per document", { try buildDocumentsPerGroup(named: name, groups: groups, paper: paper) }),
            ("Combined PDF", { try buildCombinedDocument(named: name, groups: groups, paper: paper) }),
        ]
        for (label, build) in builds {
            do {
                let built = try build()
                let packaged = try package(built)
                report += "  ▸ \(label): \(tree(built))\n"
                report += "      → shared as \(packaged.lastPathComponent)"
                    + " (\(LLFormat.bytes(fileSize(packaged))))\n"
            } catch {
                report += "  ▸ \(label): ❌ \(error.localizedDescription)\n"
            }
        }
        return report
    }

    private static func tree(_ url: URL) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return url.lastPathComponent }
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        return url.lastPathComponent + "/{" + children.map(tree).joined(separator: ", ") + "}"
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }
}
#endif
