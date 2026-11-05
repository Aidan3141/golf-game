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
        PuttRollComponent.registerComponent()
        PuttRollSystem.registerSystem()
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
        .upperLimbVisibility(.visible)  // see ur own hands on the club

        // putting is mixed, green sits on ur real floor
        ImmersiveSpace(id: AppModel.puttSpaceID) {
            PuttingView()
                .environment(appModel)
                .onAppear { appModel.puttState = .open }
                .onDisappear { appModel.puttState = .closed }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
    }
}
