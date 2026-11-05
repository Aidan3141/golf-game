import Foundation
import Testing
@testable import SwingKit

@Suite struct PuttTests {
    let flat3m = PuttSetup(hole: [0, 3])

    @Test func perfectSpeedOnLineDrops() {
        // a bit past the hole speed, dead straight
        let v = PuttSimulator.idealSpeed(for: 3.3)
        let r = PuttSimulator.simulate(speed: v, aimDegrees: 0, setup: flat3m)
        #expect(r.holed)
        #expect(r.points.last!.position.y < 0)
    }

    @Test func shortStaysShort() {
        let v = PuttSimulator.idealSpeed(for: 2.0)
        let r = PuttSimulator.simulate(speed: v, aimDegrees: 0, setup: flat3m)
        #expect(!r.holed)
        #expect(abs(r.rest.y - 2.0) < 0.05)
        #expect(abs(r.leftToHole - 1.0) < 0.05)
    }

    @Test func wayTooFastLipsOut() {
        let r = PuttSimulator.simulate(speed: 3.5, aimDegrees: 0, setup: flat3m)
        #expect(!r.holed)
        #expect(r.lippedOut)
        #expect(r.rest.y > 3)
    }

    @Test func pushedMisses() {
        let v = PuttSimulator.idealSpeed(for: 3.3)
        let r = PuttSimulator.simulate(speed: v, aimDegrees: 4, setup: flat3m)
        #expect(!r.holed)
        #expect(r.rest.x > 0.1)
    }

    @Test func slopeBreaksIt() {
        // green falls off to the right
        let tilted = PuttSetup(hole: [0, 3], slope: [0.02, 0])
        let v = PuttSimulator.idealSpeed(for: 3.3)
        let r = PuttSimulator.simulate(speed: v, aimDegrees: 0, setup: tilted)
        #expect(r.rest.x > 0.05)
    }

    @Test func strokeMapsToSpeed() {
        let s = SwingResult(handedness: .right, backswingDuration: 0.6, downswingDuration: 0.3,
                            peakWristAngularVelocity: 3, peakAcceleration: 1.5, smoothnessScore: 1,
                            pathBias: 0, confidence: 1)
        let l = PuttSimulator.launch(s, faceToAim: 2)
        #expect(abs(l.speed - 1.8) < 0.01)
        #expect(abs(l.aim - 1.8) < 0.01)
    }

    @Test func puttTips() {
        let s = SwingResult(handedness: .right, backswingDuration: 0.6, downswingDuration: 0.3,
                            peakWristAngularVelocity: 3, peakAcceleration: 1.5, smoothnessScore: 1,
                            pathBias: 0, confidence: 1)
        let holed = PuttSimulator.simulate(speed: PuttSimulator.idealSpeed(for: 3.3), aimDegrees: 0, setup: flat3m)
        #expect(Coach.puttTip(for: s, result: holed).kind == .great)
        let jab = SwingResult(handedness: .right, backswingDuration: 0.3, downswingDuration: 0.3,
                              peakWristAngularVelocity: 3, peakAcceleration: 1.5, smoothnessScore: 1,
                              pathBias: 0, confidence: 1)
        let short = PuttSimulator.simulate(speed: 0.5, aimDegrees: 0, setup: flat3m)
        #expect(Coach.puttTip(for: jab, result: short).kind == .rushedTempo)
    }

    @Test func puttingConfigIsSofter() {
        #expect(SwingDetectorConfig.putting.impactMinPeak < SwingDetectorConfig.standard.impactMinPeak)
    }

    @Test func modeMessageRoundTrips() throws {
        let env = MessageEnvelope(payload: .mode(.putt), sentAt: Date(timeIntervalSince1970: 0))
        #expect(try MessageEnvelope.decode(env.encoded()).payload == .mode(.putt))
    }
}
