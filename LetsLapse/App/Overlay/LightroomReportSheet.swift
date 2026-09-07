import SwiftUI

/// What an import actually did, and what it could not do.
///
/// The sheet exists because a Lightroom import is **lossy and always will
/// be** — two renderers, two sets of curves, and a profile look this build
/// has no control for. Applying the settings and saying nothing would leave
/// the photographer to work out for themselves why the picture is close but
/// not the same. So the losses get equal billing with the wins, in the
/// photographer's own vocabulary rather than the file's.
struct LightroomReportSheet: View {
    let report: LightroomSettingsImport.Result
    let fileName: String
    var accent: Color = LL.accent
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        "Carried across", lines: report.applied, symbol: "checkmark",
                        tint: accent,
                        empty: "Nothing — the sidecar holds no settings this build can use.")
                    section(
                        "Not carried", lines: report.unsupported, symbol: "xmark",
                        tint: .secondary,
                        empty: "Nothing — this file imported whole.")
                    footnote
                }
                .padding(18)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Imported from Lightroom")
                    .font(.system(size: 17, weight: .bold))
                Text(fileName)
                    .font(.system(size: 12))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onDone)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    @ViewBuilder private func section(
        _ title: String, lines: [String], symbol: String, tint: Color, empty: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Text("\(lines.count)")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            if lines.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                            .frame(width: 12)
                        Text(line)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// The thing no list of fields can say: matching numbers is not matching
    /// pictures. Better said once, plainly, than discovered.
    private var footnote: some View {
        Text("Values transfer; renderers do not. Lightroom's tone curves and camera profile are its own, so an imported grade lands close rather than identical — nearer on exposure and white balance, further on contrast and clarity.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
