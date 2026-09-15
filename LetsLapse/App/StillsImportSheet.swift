import SwiftUI
import LetsLapseKit

/// The stills import's question: a shoot, or a photo each?
///
/// Asked after the pick and before the copy — the moment the app has read
/// the files and the person has spent nothing. The reading
/// (`ImportedStills.reading`, docs/import-classification.md) pre-selects a
/// row when the set is clean and tags it *Detected*; when the files disagree
/// with each other it pre-selects nothing, says why in amber, and Import
/// stays inert until a row is chosen. The fix for a warned set is always one
/// the person makes — in the folder, or by choosing knowingly — never one the
/// app makes in the set.
///
/// A sibling of `ProjectImportSheet`: root-presented, blocking, Cancel
/// always reachable.
struct StillsImportSheet: View {
    @EnvironmentObject var model: AppModel
    let question: AppModel.StillsImportQuestion
    @State private var selected: ImportedStills.Reading.Kind?

    init(question: AppModel.StillsImportQuestion) {
        self.question = question
        _selected = State(initialValue: question.reading.suggested)
    }

    private var reading: ImportedStills.Reading { question.reading }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "photo.stack")
                .font(.system(size: 30))
                .foregroundStyle(LL.accent)
                .padding(.top, 30)

            Text("Import \(question.count) photos")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 14)

            Text(summaryLine)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 3)
                .padding(.horizontal, 12)

            VStack(spacing: 10) {
                choiceRow(.shoot, title: "Interval shoot", subtitle: shootSubtitle)
                choiceRow(.photos, title: "Photos", subtitle: "\(question.count) separate projects")
            }
            .padding(.top, 20)

            if let line = warningLine {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(LL.amber)
                        .padding(.top, 1)
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(LL.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 12)
                .accessibilityIdentifier("import.warning")
            }

            Spacer(minLength: 20)

            VStack(spacing: 10) {
                Button("Import") {
                    guard let selected else { return }
                    model.answerStillsImport(selected == .shoot ? .shoot : .photos)
                }
                .buttonStyle(LLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
                .opacity(selected == nil ? 0.45 : 1)
                .accessibilityIdentifier("import.confirm")

                Button("Cancel") { model.answerStillsImport(.cancel) }
                    .buttonStyle(LLSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(width: 380)
        .frame(minHeight: 300)
        .background(LL.screenBackground)
        // The only exits are the three buttons; a swipe or a click away would
        // leave the import suspended on nobody's answer.
        .interactiveDismissDisabled()
    }

    // MARK: - Rows

    private func choiceRow(_ kind: ImportedStills.Reading.Kind, title: String, subtitle: String) -> some View {
        let isSelected = selected == kind
        let isDetected = reading.suggested == kind
        return Button {
            selected = kind
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? LL.accent : Color.secondary.opacity(0.6))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        if isDetected {
                            Text("Detected")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LL.accentDeep)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(LL.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? LL.accent : LL.hairline, lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("import.kind.\(kind.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Copy

    private var summaryLine: String {
        var parts: [String] = []
        if let folder = question.folderName { parts.append(folder) }
        if !question.formats.isEmpty { parts.append(question.formats.joined(separator: ", ")) }
        if let camera = question.cameraName { parts.append(camera) }
        if let span = question.spanSeconds, span > 0 { parts.append(Self.spanText(span)) }
        return parts.joined(separator: " · ")
    }

    private var shootSubtitle: String {
        var line = "One project of \(question.count) frames"
        if let beat = reading.beatSeconds { line += ", \(Self.beatText(beat)) apart" }
        if reading.pauses > 0 { line += reading.pauses == 1 ? ", one pause" : ", \(reading.pauses) pauses" }
        return line
    }

    /// The amber line, one per reading. Written to name the files and say
    /// what the folder becomes — the tidy-up is the person's, in the Finder.
    private var warningLine: String? {
        guard let warning = reading.warnings.first else { return nil }
        let beat = reading.beatSeconds.map(Self.beatText)
        let keep: String = {
            guard let beat, reading.runFrames > 0 else { return "" }
            return "\(reading.runFrames) frames keep a \(beat) beat. "
        }()
        switch warning {
        case .strangersByName(let names):
            var line = keep + "\(Self.count(names.count, "file")) \(names.count == 1 ? "doesn't" : "don't") belong: \(Self.list(names))."
            if reading.afterCleanup == .shoot {
                line += " Without \(names.count == 1 ? "it" : "them") this folder is a shoot — move \(names.count == 1 ? "it" : "them") out and import again."
            }
            return line
        case .strangersByBeat(let names):
            return keep + "\(Self.count(names.count, "file")) \(names.count == 1 ? "doesn't" : "don't"): \(Self.list(names)). Move \(names.count == 1 ? "it" : "them") out and import again, or choose knowing \(names.count == 1 ? "it" : "they") would be \(names.count == 1 ? "a frame" : "frames") of the shoot."
        case .strangersByClock(let names):
            return keep + "\(Self.count(names.count, "file")) \(names.count == 1 ? "carries" : "carry") no capture time: \(Self.list(names))."
        case .pairs(let per):
            let formats = question.formats.joined(separator: " and ")
            return "Every frame is here \(per == 2 ? "twice" : "\(per) times")\(formats.isEmpty ? "" : " (\(formats))"). Keep one set in the folder and import again, or import all \(question.count) files as separate photos."
        case .beatChange(let at, let from, let to):
            return "The interval changes at \(at): \(Self.beatText(from)), then \(Self.beatText(to))."
        case .slow(let beat):
            return "\(question.count) numbered files, one every \(Self.beatText(beat)) — regular, but slower than a shoot is recognised at (\(Self.beatText(ImportedStills.Reading.beatCap)))."
        case .short(let count):
            return "\(count) numbered files\(beat.map { ", \($0) apart" } ?? "") — a short sequence."
        case .noClock:
            return "\(question.count) numbered files carry no capture times."
        case .irregularNames(let patterns):
            return "The file names don't run in sequence (\(patterns.joined(separator: ", ")))\(beat.map { ", though the frames keep a \($0) beat" } ?? "")."
        case .namesUnknown:
            return "These photos came without their camera names\(beat.map { "; the frames keep a \($0) beat" } ?? "")."
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Up to three names, or the first and the last.
    private static func list(_ names: [String]) -> String {
        names.count <= 3 ? names.joined(separator: ", ") : "\(names[0]) … \(names[names.count - 1])"
    }

    static func beatText(_ seconds: Double) -> String {
        if seconds >= 120 { return String(format: "%.0f min", seconds / 60) }
        if seconds >= 10 { return String(format: "%.0f s", seconds) }
        return String(format: "%.1f s", seconds)
    }

    static func spanText(_ seconds: Double) -> String {
        if seconds >= 3600 { return String(format: "%.1f h", seconds / 3600) }
        if seconds >= 60 { return String(format: "%.0f min", seconds / 60) }
        return String(format: "%.0f s", seconds)
    }
}
