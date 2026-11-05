import SwiftUI
import SwingKit

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 20) {
            Text("Golf Game")
                .font(.extraLargeTitle)
            Text("vision pro · swingkit \(SwingKit.version)")
                .foregroundStyle(.secondary)
            Text("sample tempo \(SwingResult.sample.tempoRatio, format: .number.precision(.fractionLength(1))):1")
                .font(.title3)

            Button(appModel.rangeState == .open ? "Leave Range" : "Go to Range") {
                Task { await toggleRange() }
            }
            .disabled(appModel.rangeState == .opening)
        }
        .padding(40)
    }

    private func toggleRange() async {
        switch appModel.rangeState {
        case .open:
            await dismissImmersiveSpace()
        case .closed:
            appModel.rangeState = .opening
            // state flips to .open in onAppear, so only handle fail cases here
            switch await openImmersiveSpace(id: AppModel.rangeSpaceID) {
            case .opened: break
            default: appModel.rangeState = .closed
            }
        case .opening:
            break
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
