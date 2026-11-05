import Foundation
import Observation
import SwingKit

// one hit = the swing + where the ball goes
struct Shot: Identifiable, Equatable {
    let id = UUID()
    let swing: SwingResult
    let flight: FlightResult
    let live: Bool  // real swing from the watch, ball goes right away (no club replay)
    let tip: CoachingTip
}

@MainActor
@Observable
final class AppModel {
    static let rangeSpaceID = "DrivingRange"

    enum SpaceState {
        case closed, opening, open
    }

    enum ViewMode: String, CaseIterable {
        case firstPerson = "First person"
        case behind = "Behind ball"
    }

    var rangeState = SpaceState.closed
    var viewMode = ViewMode.firstPerson

    // wrist roll -> curve calibration. flip if the ball goes the wrong way
    var flipCurve = false
    var curveStrength = 1.0
    static let fullCurveDegrees = 15.0  // this much roll (x strength) = full slice/hook

    let liveClub = LiveClub()

    // tempo trainer metronome in the range
    var tempoTrainerOn = false
    var trainerBackswing = 0.9  // s, downswing = 1/3 of this
    var testSwing = TestSwingSettings()
    var tuning = FlightTuning.standard
    private(set) var lastShot: Shot?
    private(set) var session: [Shot] = []
    var cardShot: Shot?  // shot card in the range, set once the ball lands

    var stats: SessionStats {
        SessionStats(swings: session.map(\.swing), flights: session.map(\.flight))
    }
    var bestShot: Shot? { session.max { $0.flight.carry < $1.flight.carry } }

    func newSession() {
        session.removeAll()
        cardShot = nil
    }

    // sliders feed the mock, real swings come in over the network from the phone
    let mockSource = MockSwingSource()
    let network = NetworkSwingReceiver()
    @ObservationIgnored private var listenTasks: [Task<Void, Never>] = []

    init() {
        listen(to: mockSource, live: false)
        listen(to: network, live: true)
        network.onClub = { [liveClub] angle, phase in
            liveClub.update(angle: angle, phase: phase)
        }
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
        var swing = swing
        if let face = swing.faceAngle {
            swing = swing.with(pathBias: pathBias(forFace: face))
        }
        let flight = FlightSimulator.simulate(swing: swing, tuning: tuning)
        let shot = Shot(swing: swing, flight: flight, live: live, tip: Coach.tip(for: swing, flight: flight))
        lastShot = shot
        session.append(shot)
    }

    func pathBias(forFace face: Double) -> Double {
        let p = face / Self.fullCurveDegrees * curveStrength * (flipCurve ? -1 : 1)
        return min(max(p, -1), 1)
    }

    // the hand used for setup when theres no shot yet
    var handedness: Handedness { testSwing.handedness }
}
