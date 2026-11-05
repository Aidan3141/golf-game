import SwiftUI

@main
struct GolfGameApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: AppModel.rangeSpaceID) {
            RangeView()
                .environment(appModel)
                .onAppear { appModel.rangeState = .open }
                .onDisappear { appModel.rangeState = .closed }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
