import Foundation
import Observation
import SwingKit

// one hit = the swing + where the ball goes
struct Shot: Identifiable, Equatable {
    let id = UUID()
    let swing: SwingResult
    let flight: FlightResult
}

@MainActor
@Observable
final class AppModel {
    static let rangeSpaceID = "DrivingRange"

    enum SpaceState {
        case closed, opening, open
    }

    var rangeState = SpaceState.closed
    var testSwing = TestSwingSettings()
    var tuning = FlightTuning.standard
    private(set) var lastShot: Shot?

    // fake for now, real watch -> iphone -> avp source drops in here in M5
    let mockSource = MockSwingSource()
    @ObservationIgnored private var listenTask: Task<Void, Never>?

    init() {
        listen(to: mockSource)
    }

    func listen(to source: some SwingSource) {
        listenTask?.cancel()
        let stream = source.swings
        listenTask = Task { [weak self] in
            for await swing in stream {
                self?.hit(swing)
            }
        }
    }

    func hit(_ swing: SwingResult) {
        lastShot = Shot(swing: swing, flight: FlightSimulator.simulate(swing: swing, tuning: tuning))
    }
}
