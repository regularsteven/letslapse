import SwiftUI
import LetsLapseKit

// MARK: - The Gallery panel's Info and Metadata groups
//
// Info is read-only and comes from the `imported` layer: what the camera and
// the file said. Metadata is the IPTC Core set a person edits, in the order
// the brief lists them, each row saying whether its value came from the file
// or was edited here, with a revert. An interval project edits the
// project-level record by default and can scope to one frame.
// (docs/data-model-scale-and-metadata-2026-09-12.md §7; SVG mirrors to follow
// sign-off — see docs/design/macOS/INDEX.md.)

/// The scope switch and frame chooser an interval project gets above both
/// groups; a Photo or video project is one asset and shows nothing here.
struct MetadataScopeControl: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    @Binding var scope: AppModel.MetadataScope

    private var frames: [String] { model.frameNames(for: capture) }

    private var frameIndex: Int? {
        guard case .frame(let name) = scope else { return nil }
        return frames.firstIndex(of: name)
    }

    var body: some View {
        if frames.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Scope", selection: Binding(
                    get: { frameIndex == nil ? 0 : 1 },
                    set: { scope = $0 == 0 ? .project : .frame(frames[frameIndex ?? 0]) }
                )) {
                    Text("Whole project").tag(0)
                    Text("This frame").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let index = frameIndex {
                    HStack(spacing: 8) {
                        stepButton("chevron.left", enabled: index > 0) { scope = .frame(frames[index - 1]) }
                        VStack(spacing: 1) {
                            Text((frames[index] as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(index + 1) of \(frames.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        stepButton("chevron.right", enabled: index < frames.count - 1) { scope = .frame(frames[index + 1]) }
                    }
                }
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Read-only: camera, lens, exposure, captured, GPS, dimensions, software.
struct MetadataInfoSection: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    var scope: AppModel.MetadataScope

    var body: some View {
        // Reading `metadataRevision` is what re-renders the group when the
        // background reader lands a project's records.
        let _ = model.metadataRevision
        let resolved = model.resolvedMetadata(for: capture, scope: scope)
        let m = resolved.value
        VStack(alignment: .leading, spacing: 0) {
            LLSectionHeader("Info")
                .padding(.bottom, 4)
            if let camera = m.cameraLine { infoRow("Camera", camera) }
            if let lens = m.camera?.lens { infoRow("Lens", lens) }
            if let exposure = m.exposureLine { infoRow("Exposure", exposure) }
            if let captured = m.captured { infoRow("Captured", Self.capturedLabel(captured)) }
            if let gps = m.gpsLine, let lat = m.gps?.lat, let lon = m.gps?.lon {
                infoRow("GPS") {
                    HStack(spacing: 6) {
                        Text(gps)
                        if let url = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%@", lat, lon,
                                                        (m.title ?? capture.displayTitle).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")) {
                            Link(destination: url) {
                                Image(systemName: "map")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .accessibilityLabel("Open in Maps")
                        }
                    }
                }
            }
            if let width = m.dimensions?.width, let height = m.dimensions?.height {
                infoRow("Size", "\(width) × \(height)" + (formatLabel.isEmpty ? "" : " · \(formatLabel)"))
            }
            if let software = m.software { infoRow("Software", software) }
            if m.cameraLine == nil, m.exposureLine == nil, m.captured == nil, m.gps == nil, m.dimensions == nil {
                Text(emptyCopy)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    /// The frame's own format in frame scope; the shoot's set otherwise.
    private var formatLabel: String {
        if case .frame(let name) = scope {
            let ext = (name as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "" : AppModel.CaptureProject.sourceFormatLabel(for: ext)
        }
        return capture.sourceFormatLabels.joined(separator: "+")
    }

    /// Why the group is empty: the reader has not landed yet, the frames of
    /// an interval shoot disagree (so nothing is true of the whole), or the
    /// file simply carries nothing.
    private var emptyCopy: String {
        let records = model.assetRecords(for: capture)
        if records.isEmpty { return "Reading the files…" }
        if scope == .project, model.frameNames(for: capture).count > 1,
           records.ordered.contains(where: { $0.imported?.camera != nil || $0.imported?.exposure != nil }) {
            return "Varies by frame — choose This frame."
        }
        return "Nothing in the file."
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        infoRow(label) { Text(value) }
    }

    @ViewBuilder
    private func infoRow<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content()
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    /// "31 Aug 2026, 20:29:30 (UTC+01:00)" — shown in the zone the file
    /// carried, which is where the picture was taken; no zone → no suffix.
    static func capturedLabel(_ text: String) -> String {
        guard let date = AssetMetadata.parseISO8601(text) else { return text }
        var zone = TimeZone.current
        var suffix = ""
        if text.hasSuffix("Z") {
            zone = TimeZone(secondsFromGMT: 0)!
            suffix = " (UTC)"
        } else if let match = text.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) {
            let offset = String(text[match])
            let sign: Int = offset.hasPrefix("-") ? -1 : 1
            let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let tz = TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60)) {
                zone = tz
                suffix = " (UTC\(offset))"
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = zone
        formatter.dateFormat = "d MMM yyyy, HH:mm:ss"
        return formatter.string(from: date) + suffix
    }
}

/// Editable: the IPTC Core fields in the brief's order, then the creator
/// contact block, the location block, and keywords (the tag editor).
struct MetadataEditSection: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    var scope: AppModel.MetadataScope

    var body: some View {
        let _ = model.metadataRevision
        let resolved = model.resolvedMetadata(for: capture, scope: scope)
        VStack(alignment: .leading, spacing: 10) {
            LLSectionHeader("Metadata")
            textRow(.title, resolved)
            textRow(.caption, resolved, multiline: true)
            textRow(.creator, resolved, placeholder: "Name, name")
            textRow(.rights, resolved, placeholder: "© year name")
            ratingRow(resolved)
            statusRow(resolved)
            textRow(.rightsURL, resolved, placeholder: "https://")
            textRow(.usageTerms, resolved)

            groupLabel("Creator contact")
            ForEach([MetadataField.contactAddress, .contactCity, .contactState, .contactPostcode,
                     .contactCountry, .contactPhone, .contactEmail, .contactWebsite], id: \.self) { field in
                textRow(field, resolved)
            }

            groupLabel("Location")
            ForEach([MetadataField.locationSublocation, .locationCity, .locationState,
                     .locationCountry, .locationCountryCode], id: \.self) { field in
                textRow(field, resolved)
            }

            keywordsRow(resolved)
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    // MARK: Rows

    private func rowKey(_ field: MetadataField) -> String {
        let scopeKey: String
        switch scope {
        case .project: scopeKey = "project"
        case .frame(let name): scopeKey = name
        }
        return "\(capture.id.uuidString)|\(scopeKey)|\(field.rawValue)"
    }

    private func textRow(_ field: MetadataField, _ resolved: AppModel.ResolvedMetadata,
                         placeholder: String = "", multiline: Bool = false) -> some View {
        MetadataTextRow(
            field: field,
            text: resolved.value[field]?.textValue ?? "",
            origin: resolved.origin(field),
            placeholder: placeholder,
            multiline: multiline,
            commit: { text in
                let value: MetadataValue? = text.isEmpty ? nil : (field == .creator ? .list(MetadataValue.text(text).listValue ?? []) : .text(text))
                model.setMetadata(value, for: field, on: capture, scope: scope)
            },
            revert: { model.revertMetadata(field, on: capture, scope: scope) })
        .id(rowKey(field))
    }

    private func ratingRow(_ resolved: AppModel.ResolvedMetadata) -> some View {
        let rating = resolved.value.rating ?? 0
        return MetadataRowFrame(field: .rating, origin: resolved.origin(.rating),
                                revert: { model.revertMetadata(.rating, on: capture, scope: scope) }) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        // The same star again clears, as it does in Lightroom.
                        model.setMetadata(.integer(star == rating ? 0 : star), for: .rating, on: capture, scope: scope)
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(star <= rating ? LL.amber : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func statusRow(_ resolved: AppModel.ResolvedMetadata) -> some View {
        let status = resolved.value.rightsStatus ?? .unknown
        return MetadataRowFrame(field: .rightsStatus, origin: resolved.origin(.rightsStatus),
                                revert: { model.revertMetadata(.rightsStatus, on: capture, scope: scope) }) {
            Picker("Copyright status", selection: Binding(
                get: { status },
                set: { model.setMetadata(.text($0.rawValue), for: .rightsStatus, on: capture, scope: scope) }
            )) {
                Text("Copyrighted").tag(AssetMetadata.RightsStatus.copyrighted)
                Text("Public domain").tag(AssetMetadata.RightsStatus.publicDomain)
                Text("Unknown").tag(AssetMetadata.RightsStatus.unknown)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keywordsRow(_ resolved: AppModel.ResolvedMetadata) -> some View {
        MetadataRowFrame(field: .keywords, origin: resolved.origin(.keywords),
                         revert: { model.revertMetadata(.keywords, on: capture, scope: scope) }) {
            TagField(
                tags: Binding(
                    get: { resolved.value.keywords ?? [] },
                    set: { model.setMetadata(.list($0), for: .keywords, on: capture, scope: scope) }),
                libraryTags: model.libraryTags)
        }
    }
}

/// A row's chrome: the label, the "from file / edited here" marker with its
/// revert, and the control underneath, full width — a 300 pt panel has no
/// room for a label column beside a text field.
struct MetadataRowFrame<Content: View>: View {
    var field: MetadataField
    var origin: AppModel.MetadataOrigin?
    var revert: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                switch origin {
                case .edited?:
                    Text("edited here")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LL.accent)
                    Button(action: revert) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LL.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Revert to the file's value")
                    .accessibilityLabel("Revert \(field.label)")
                case .imported?:
                    Text("from file")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                case nil:
                    EmptyView()
                }
            }
            content()
        }
        .padding(.vertical, 2)
    }
}

/// A text field that commits on Return and on losing focus, never per
/// keystroke — an edit is one line appended to the record, not one per key.
struct MetadataTextRow: View {
    var field: MetadataField
    var text: String
    var origin: AppModel.MetadataOrigin?
    var placeholder: String = ""
    var multiline = false
    var commit: (String) -> Void
    var revert: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        MetadataRowFrame(field: field, origin: origin, revert: revert) {
            Group {
                if multiline {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                } else {
                    TextField(placeholder, text: $draft)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($focused)
            .onSubmit(commitIfChanged)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitIfChanged() }
            }
            #if os(iOS)
            .textInputAutocapitalization(field == .contactEmail || field == .contactWebsite || field == .rightsURL ? .never : .sentences)
            .keyboardType(field == .contactEmail ? .emailAddress : (field == .contactWebsite || field == .rightsURL ? .URL : .default))
            #endif
        }
        .onAppear { draft = text }
        // The prop moves under a focused field only when something other
        // than this field changed the record — a revert, a re-read — and
        // then the field must show it.
        .onChange(of: text) { _, newValue in
            draft = newValue
        }
    }

    private func commitIfChanged() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else { return }
        commit(trimmed)
    }
}
