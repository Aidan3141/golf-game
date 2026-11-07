import Foundation
import Observation
import SwingKit

// one hit = the swing + where the ball goes
struct Shot: Identifiable, Equatable {
    var id = UUID()
    let swing: SwingResult
    let flight: FlightResult
    let live: Bool  // real swing from the watch, ball goes right away (no club replay)
    let tip: CoachingTip
    var provisional = false  // launched off the hand club contact, watch numbers not in yet
    var refined = false  // same shot, watch numbers swapped in mid flight
}

struct PuttShot: Identifiable, Equatable {
    var id = UUID()
    let swing: SwingResult
    let setup: PuttSetup
    let result: PuttResult
    let live: Bool
    let tip: CoachingTip
    var refined = false  // same putt, watch tempo swapped in
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
    let handTracking = HandTracking()
    var addressCheckOn = true  // hand tracking on/off (club + address check)

    enum ClubSource: String, CaseIterable {
        case hybrid = "Hybrid"
        case hands = "Hands"
        case watch = "Watch"
    }
    var clubSource = ClubSource.hybrid
    var handStats = "—"
    var relockToken = 0  // bump to make the hand club forget its lock

    // club tuning, all live from the window
    var handBackend = HandTracking.Backend.anchored
    var manualLookaheadMs = 60.0 {
        didSet { handTracking.lookahead = manualLookaheadMs / 1000 }
    }
    var handSmoothing = 0.0  // manual mode 1€ filter, 0 = off
    var watchExtrapolate = true {
        didSet { liveClub.extrapolate = watchExtrapolate }
    }
    var watchDisplayLeadMs = 35.0 {
        didSet { liveClub.displayLead = watchDisplayLeadMs / 1000 }
    }

    // per swing frame logs for debugging the club, shareable from the window
    let swingLogger = SwingLogger()
    // records a whole shot (head, hands, club, ball) for the mac showcase render
    let showcase = ShowcaseRecorder()
    var lastSwingLog: URL?

    // contact launch waits this long for the watch to refine it
    static let refineWindow = 3.0  // the full watch swing comes over watchconnectivity, can take a sec or 2
    @ObservationIgnored private var contactAt: Double?
    @ObservationIgnored private var contactImpact: Double?  // when that shot was hit (headset uptime)
    // a ball is flying/rolling (or sitting out where it stopped). live swings that arent
    // the shot being refined get ignored, a fast wrist flick mid flight used to bend the arc
    @ObservationIgnored var ballBusy = false
    var resetBallToken = 0  // bump to put the ball back right now

    func resetBall() {
        contactAt = nil  // a late watch swing cant refine/replay the old shot
        contactImpact = nil
        resetBallToken += 1
    }
    var gripHands = GripHands.both

    enum GripHands: String, CaseIterable {
        case both = "Both hands"
        case lead = "Lead"
        case trail = "Trail"
    }
    @ObservationIgnored private var contactFace: Double?

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
        network.onClub = { [liveClub] sample in
            liveClub.update(sample)
        }
        network.onQuickImpact = { [weak self] q in
            self?.quickImpact(q)
        }
        network.start()
        liveClub.extrapolate = watchExtrapolate
        liveClub.displayLead = watchDisplayLeadMs / 1000
        swingLogger.settings = { [weak self] in self?.tuningSnapshot ?? [:] }
        swingLogger.onWrite = { [weak self] url in self?.lastSwingLog = url }
        if ProcessInfo.processInfo.arguments.contains("-showcase") { showcase.isOn = true }
    }

    func listen(to source: some SwingSource, live: Bool) {
        let stream = source.swings
        listenTasks.append(Task { [weak self] in
            for await swing in stream {
                self?.hit(swing, live: live)
            }
        })
    }

    func startHandTracking() {
        handTracking.lookahead = manualLookaheadMs / 1000
        handTracking.start(handBackend)
        addressCheck.set(handTracking.state == .unsupported ? .unsupported : .noHands)
    }

    func stopHandTracking() {
        handTracking.stop()
        addressCheck.set(.off)
    }

    // what the club was set to, saved w/ every swing log
    var tuningSnapshot: [String: String] {
        [
            "clubSource": clubSource.rawValue,
            "handBackend": handBackend.rawValue,
            "manualLookaheadMs": String(format: "%.0f", manualLookaheadMs),
            "handSmoothing": String(format: "%.2f", handSmoothing),
            "watchExtrapolate": "\(watchExtrapolate)",
            "watchDisplayLeadMs": String(format: "%.0f", watchDisplayLeadMs),
            "mode": mode.rawValue,
            "hand": handedness.rawValue,
            "liveClub": network.clubStats,
        ]
    }

    // the hand club hit the ball. launch right now off what the hands say, the watch swing
    // (lands ~0.1-0.3s later thru the phone) refines it. face angle from the hands is physical,
    // so no flip/strength calibration here
    func contact(headSpeed: Double, faceDegrees: Double) {
        guard !ballBusy else { return }
        swingLogger.mark(String(format: "contact %.1f m/s face %+.1f", headSpeed, faceDegrees))
        let now = ProcessInfo.processInfo.systemUptime
        contactAt = now
        contactImpact = now
        contactFace = faceDegrees
        if mode == .putt {
            let speed = min(headSpeed * 1.6, PuttTuning.standard.maxSpeed)
            let r = PuttSimulator.simulate(speed: speed, aimDegrees: faceDegrees * PuttTuning.standard.aimDegreesPerFaceDegree, setup: puttSetup)
            let placeholder = SwingResult(handedness: handedness, backswingDuration: 0.6, downswingDuration: 0.3,
                                          peakWristAngularVelocity: speed / PuttTuning.standard.speedPerWristRadPerSec,
                                          peakAcceleration: 1, smoothnessScore: 0.8, pathBias: 0, confidence: 0.6)
            puttsThisHole += 1
            totalPutts += 1
            lastPutt = PuttShot(swing: placeholder, setup: puttSetup, result: r, live: true,
                                tip: Coach.puttTip(for: placeholder, result: r))
            return
        }
        // 7 iron smash ~1.35, ball = wrist x 2.72 -> wrist ~ 0.5 x head speed
        let swing = SwingResult(handedness: handedness, backswingDuration: 0.9, downswingDuration: 0.3,
                                peakWristAngularVelocity: headSpeed * 0.5, peakAcceleration: 10,
                                smoothnessScore: 0.8, pathBias: facePath(faceDegrees), confidence: 0.6)
        let flight = FlightSimulator.simulate(swing: swing, tuning: tuning)
        let shot = Shot(swing: swing, flight: flight, live: true,
                        tip: Coach.tip(for: swing, flight: flight), provisional: true)
        lastShot = shot
        session.append(shot)
    }

    // the watch saw impact (fast lane, ~tens of ms) but the hand club didnt hit the ball (hands
    // lost, blur). launch off the quick numbers now, the full swing refines it when it lands
    func quickImpact(_ q: QuickImpact) {
        let now = ProcessInfo.processInfo.systemUptime
        if let at = contactAt, now - at < 1.0 { return }  // hand club already launched this one
        guard !ballBusy else { return }  // ball already out there, this is a wrist flick not a shot
        swingLogger.mark(String(format: "watch impact %.0f rad/s", q.wristSpeed))
        contactAt = now
        contactImpact = q.time
        contactFace = nil
        var swing = q.swing(handedness: handedness)
        if mode == .putt {
            putt(swing, live: true)
            return
        }
        if let face = swing.faceAngle { swing = swing.with(pathBias: pathBias(forFace: face)) }
        let flight = FlightSimulator.simulate(swing: swing, tuning: tuning)
        let shot = Shot(swing: swing, flight: flight, live: true,
                        tip: Coach.tip(for: swing, flight: flight), provisional: true)
        lastShot = shot
        session.append(shot)
    }

    // face open to the right -> slice for a righty. ~15 deg = full curve
    private func facePath(_ face: Double) -> Double {
        let sign: Double = handedness == .right ? -1 : 1
        return min(max(sign * face / Self.fullCurveDegrees, -1), 1)
    }

    func hit(_ swing: SwingResult, live: Bool = false) {
        if live { swingLogger.mark(String(format: "watch swing tempo %.2f", swing.tempoRatio)) }
        // watch swing right after a hand contact = same shot, swap the real numbers in. only if
        // its impact lines up w/ that shot (a flick while the ball flies is a different "swing")
        if live, let at = contactAt, ProcessInfo.processInfo.systemUptime - at < Self.refineWindow {
            let impact = network.impactTime(for: swing.id)
            if let impact, let shotImpact = contactImpact, abs(impact - shotImpact) > 0.6 {
                return  // not the same swing, ignore it
            }
            contactAt = nil
            contactImpact = nil
            refine(with: swing)
            return
        }
        if live && ballBusy { return }  // ball still out there, not a new shot
        if mode == .putt {
            putt(swing, live: live)
            return
        }
        var swing = swing
        if let face = swing.faceAngle {
            swing = swing.with(pathBias: pathBias(forFace: face))
        }
        let flight = FlightSimulator.simulate(swing: swing, tuning: tuning)
        // always launches from the tee. skipping ahead into the flight to "catch up" w/ the real
        // impact made the ball pop out mid air + the trail start in a weird spot
        let shot = Shot(swing: swing, flight: flight, live: live, tip: Coach.tip(for: swing, flight: flight))
        lastShot = shot
        session.append(shot)
    }

    private func refine(with watch: SwingResult) {
        if mode == .putt {
            // putt speed from the hands is good (slow motion), just take the watch tempo for the card
            guard let p = lastPutt else { return }
            lastPutt = PuttShot(id: p.id, swing: watch, setup: p.setup, result: p.result, live: true,
                                tip: Coach.puttTip(for: watch, result: p.result), refined: true)
            return
        }
        guard let old = lastShot, old.provisional else { return }
        // hand face if the hand club hit it, else the watch wrist roll (w/ the flip/strength calibration)
        let path = contactFace.map(facePath) ?? watch.faceAngle.map(pathBias(forFace:)) ?? watch.pathBias
        let swing = watch.with(pathBias: path)
        let flight = FlightSimulator.simulate(swing: swing, tuning: tuning)
        let shot = Shot(id: old.id, swing: swing, flight: flight, live: true,
                        tip: Coach.tip(for: swing, flight: flight), provisional: false, refined: true)
        lastShot = shot
        if let i = session.lastIndex(where: { $0.id == old.id }) { session[i] = shot }
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
