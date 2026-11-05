import SwiftUI

@main
struct GolfGameApp: App {
    static let mainWindowID = "main"
    @State private var appModel = AppModel()

    init() {
        BallFlightComponent.registerComponent()
        BallFlightSystem.registerSystem()
        ClubSwingComponent.registerComponent()
        ClubSwingSystem.registerSystem()
        LiveClubComponent.registerComponent()
        LiveClubSystem.registerSystem()
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 560, height: 820)

        ImmersiveSpace(id: AppModel.rangeSpaceID) {
            RangeView()
                .environment(appModel)
                .onAppear { appModel.rangeState = .open }
                .onDisappear { appModel.rangeState = .closed }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
