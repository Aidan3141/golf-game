import Observation

@MainActor
@Observable
final class AppModel {
    static let rangeSpaceID = "DrivingRange"

    enum SpaceState {
        case closed, opening, open
    }

    var rangeState = SpaceState.closed
}
