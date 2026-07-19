import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)
            ProgressView(value: model.progress) {
                Text(model.statusMessage.isEmpty ? "Processing..." : model.statusMessage)
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 48)
            Text("\(Int(model.progress * 100)) %")
                .font(.title2.monospacedDigit())
                .foregroundStyle(.secondary)

            if let jobFolderURL = model.jobFolderURL {
                VStack(spacing: 4) {
                    Text("Job folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(jobFolderURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            if !model.jobLogLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.jobLogLines, id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 180)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }

            Button("Cancel", role: .destructive) {
                model.cancelProcessing()
            }
            Spacer(minLength: 20)
        }
        .navigationTitle("Processing")
    }
}
