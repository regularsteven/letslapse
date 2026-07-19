import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ProgressView(value: model.progress) {
                Text("Blending on the GPU…")
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 48)
            Text("\(Int(model.progress * 100)) %")
                .font(.title2.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel", role: .destructive) {
                model.cancelProcessing()
            }
            Spacer()
        }
        .navigationTitle("Processing")
    }
}
