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

/// The export sheet: format first, then what to do with it.
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
    @State private var isWorking = false
    @State private var result: ScanShareItem?
    @State private var failure: String?
    /// Measured off the main actor when the format changes; nil until the
    /// first measurement lands, and the row simply omits the size until then.
    @State private var estimate: Int64?

    private var pages: [ScanPage] {
        guard let selection else { return session.pages }
        return session.pages.filter { selection.contains($0.number) }
    }

    private var title: String {
        pages.count == 1 ? "Export 1 page" : "Export \(pages.count) pages"
    }

    private var documentName: String {
        "Scan " + session.createdAt.formatted(
            .dateTime.day().month(.abbreviated).hour().minute())
            .replacingOccurrences(of: ":", with: ".")
    }

    var body: some View {
        content
            .task(id: "\(format.rawValue)|\(pages.count)") {
                guard format == .pdf else { return }
                let files = pages.map(\.viewable)
                let format = format
                let paper = session.paper
                estimate = await Task.detached(priority: .utility) {
                    ScanExport.estimatedBytes(pages: files, format: format, paper: paper)
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
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, row.detail == nil ? 17 : 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
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
            Picker("Format", selection: $format) {
                ForEach(ScanExportFormat.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 11)
            Text(format.caption(paper: session.paper))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Rows

    private struct Row {
        var title: String
        var detail: String?
        var isPrimary = true
        var isMuted = false
        var action: () -> Void
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let ext = format == .pdf ? "pdf" : (format == .jpeg ? "jpg" : "heic")
        let range = pages.count == 1
            ? String(format: "page-001.%@", ext)
            : String(format: "page-001.%@ … page-%03d.%@", ext, pages.count, ext)

        if format == .pdf {
            rows.append(Row(
                title: pages.count == 1 ? "One PDF, 1 page" : "One PDF, \(pages.count) pages",
                detail: "\(documentName).pdf"
                    + (estimate.map { " · ≈ \(LLFormat.bytes($0))" } ?? ""),
                action: { exportDocument() }))
            rows.append(Row(
                title: "One PDF per page",
                detail: range,
                isPrimary: false,
                action: { exportFolder() }))
        } else {
            rows.append(Row(
                title: selection == nil ? "Export all pages" : "Export selected pages",
                detail: range,
                action: { exportFolder() }))
        }

        if selection == nil {
            rows.append(Row(
                title: "Export selected pages…",
                isPrimary: false,
                action: {
                    dismiss()
                    onSelectPages()
                }))
        }

        rows.append(Row(
            title: "View as timelapse",
            isPrimary: false,
            isMuted: true,
            action: {
                dismiss()
                onViewAsTimelapse()
            }))
        return rows
    }

    /// Header, the rows as they will actually be laid out, and the Cancel card
    /// — so the sheet is exactly as tall as what is in it whichever format is
    /// chosen.
    private var sheetHeight: CGFloat {
        let rowHeight = rows.reduce(CGFloat(0)) { $0 + ($1.detail == nil ? 55 : 73) }
        return 152 + rowHeight + 70
    }

    // MARK: Work

    private func exportFolder() {
        run { name, files in
            try ScanExport.buildFolder(
                named: name,
                pages: files.enumerated().map { (number: $0.offset + 1, url: $0.element) },
                format: format)
        }
    }

    private func exportDocument() {
        let paper = session.paper
        run { name, files in
            try ScanExport.buildDocument(named: name, pages: files, paper: paper)
        }
    }

    private func run(_ build: @escaping (String, [URL]) throws -> URL) {
        guard !isWorking else { return }
        isWorking = true
        let name = documentName
        let files = pages.map(\.viewable)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do { return .success(try build(name, files)) } catch { return .failure(error) }
            }.value
            isWorking = false
            switch outcome {
            case .success(let url): result = ScanShareItem(url: url)
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}
