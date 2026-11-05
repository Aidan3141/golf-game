import Foundation
import Observation
import SwingKit

// one hit = the swing + where the ball goes
struct Shot: Identifiable, Equatable {
    let id = UUID()
    let swing: SwingResult
    let flight: FlightResult
    let live: Bool  // real swing from the watch, ball goes right away (no club replay)
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

    // sliders feed the mock, real swings come in over the network from the phone
    let mockSource = MockSwingSource()
    let network = NetworkSwingReceiver()
    @ObservationIgnored private var listenTasks: [Task<Void, Never>] = []

    init() {
        listen(to: mockSource, live: false)
        listen(to: network, live: true)
        network.start()
    }

    func listen(to source: some SwingSource, live: Bool) {
        let stream = source.swings
        listenTasks.append(Task { [weak self] in
            for await swing in stream {
                self?.hit(swing, live: live)
            }
        })
    }

    func hit(_ swing: SwingResult, live: Bool = false) {
        lastShot = Shot(swing: swing, flight: FlightSimulator.simulate(swing: swing, tuning: tuning), live: live)
    }
}
