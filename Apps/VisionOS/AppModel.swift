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

struct PuttShot: Identifiable, Equatable {
    let id = UUID()
    let swing: SwingResult
    let setup: PuttSetup
    let result: PuttResult
    let live: Bool
    let tip: CoachingTip
}

@MainActor
@Observable
final class AppModel {
    static let rangeSpaceID = "DrivingRange"
    static let puttSpaceID = "PuttingGreen"

    enum SpaceState {
        case closed, opening, open
    }

    enum ViewMode: String, CaseIterable {
        case firstPerson = "First person"
        case behind = "Behind ball"
    }

    var rangeState = SpaceState.closed
    var puttState = SpaceState.closed {
        didSet { network.mode = mode }
    }
    var mode: SwingMode { puttState == .closed ? .full : .putt }

    // putting
    private(set) var puttSetup = PuttSetup(hole: [0, 2.5])
    private(set) var lastPutt: PuttShot?
    var puttCard: PuttShot?
    private(set) var puttsThisHole = 0
    private(set) var holesPlayed = 0
    private(set) var totalPutts = 0
    var testPuttSpeed = 3.0  // rad/s stroke
    var testPuttFace = 0.0  // deg
    var viewMode = ViewMode.firstPerson

    // wrist roll -> curve calibration. flip if the ball goes the wrong way
    var flipCurve = false
    var curveStrength = 1.0
    static let fullCurveDegrees = 15.0  // this much roll (x strength) = full slice/hook

    let liveClub = LiveClub()
    let addressCheck = AddressCheck()
    var addressCheckOn = false

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
        if mode == .putt {
            putt(swing, live: live)
            return
        }
        var swing = swing
        if let face = swing.faceAngle {
            swing = swing.with(pathBias: pathBias(forFace: face))
        }
        let flight = FlightSimulator.simulate(swing: swing, tuning: tuning)
        let shot = Shot(swing: swing, flight: flight, live: live, tip: Coach.tip(for: swing, flight: flight))
        lastShot = shot
        session.append(shot)
    }

    func putt(_ swing: SwingResult, live: Bool) {
        // same flip + strength as full swings so one calibration covers both
        let face = (swing.faceAngle ?? 0) * curveStrength * (flipCurve ? -1 : 1)
        let l = PuttSimulator.launch(swing, faceToAim: face)
        let r = PuttSimulator.simulate(speed: l.speed, aimDegrees: l.aim, setup: puttSetup)
        puttsThisHole += 1
        totalPutts += 1
        lastPutt = PuttShot(swing: swing, setup: puttSetup, result: r, live: live, tip: Coach.puttTip(for: swing, result: r))
    }

    // random 1.5-4.5m putt w/ a little break
    func newHole() {
        let d = Double.random(in: 1.5...4.5)
        let grade = Double.random(in: 0...0.015)
        let dir = Double.random(in: 0..<(2 * .pi))
        puttSetup = PuttSetup(hole: [0, d], slope: [cos(dir) * grade, sin(dir) * grade])
        puttsThisHole = 0
        puttCard = nil
        lastPutt = nil
    }

    func holed() {
        holesPlayed += 1
    }

    // what to tell u about the break, from ur side of the ball
    var breakText: String {
        let side = puttSetup.slope.x
        let along = puttSetup.slope.y
        var parts: [String] = []
        if abs(side) > 0.004 { parts.append(side > 0 ? "breaks right" : "breaks left") }
        if abs(along) > 0.004 { parts.append(along > 0 ? "downhill" : "uphill") }
        return parts.isEmpty ? "flat" : parts.joined(separator: ", ")
    }

    var testPutt: SwingResult {
        SwingResult(handedness: handedness, backswingDuration: 0.6, downswingDuration: 0.3,
                    peakWristAngularVelocity: testPuttSpeed, peakAcceleration: 1.5,
                    smoothnessScore: 0.9, pathBias: 0, confidence: 1, faceAngle: testPuttFace)
    }

    func pathBias(forFace face: Double) -> Double {
        let p = face / Self.fullCurveDegrees * curveStrength * (flipCurve ? -1 : 1)
        return min(max(p, -1), 1)
    }

    // the hand used for setup when theres no shot yet
    var handedness: Handedness { testSwing.handedness }
}
