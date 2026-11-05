import Foundation
import Testing
@testable import SwingKit

private func swing(
    wrist: Double = 22, back: Double = 0.75, down: Double = 0.25,
    smooth: Double = 1, path: Double = 0, hand: Handedness = .right,
    id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
) -> SwingResult {
    SwingResult(id: id, timestamp: Date(timeIntervalSince1970: 0), handedness: hand,
                backswingDuration: back, downswingDuration: down,
                peakWristAngularVelocity: wrist, peakAcceleration: 9,
                smoothnessScore: smooth, pathBias: path, confidence: 1)
}

@Suite struct FlightTests {
    @Test func sampleSwingIsSevenIronIsh() {
        let r = FlightSimulator.simulate(swing: .sample)
        let carry = Units.yards(r.carry)
        #expect(carry > 150 && carry < 200, "carry \(carry) yd")
    }

    @Test func perfectSwingGoesStraight() {
        let r = FlightSimulator.simulate(swing: swing())
        #expect(abs(Units.yards(r.offline)) < 1)
    }

    @Test(arguments: [Handedness.right, .left])
    func sliceAndHookCurveRightWay(hand: Handedness) {
        let slice = FlightSimulator.simulate(swing: swing(path: -1, hand: hand))
        let hook = FlightSimulator.simulate(swing: swing(path: 1, hand: hand))
        // rh slice goes right (+x), lh slice goes left
        let sign: Double = hand == .right ? 1 : -1
        #expect(slice.offline * sign > Units.meters(yards: 10))
        #expect(hook.offline * sign < -Units.meters(yards: 10))
    }

    @Test func fasterSwingGoesFarther() {
        let slow = FlightSimulator.simulate(swing: swing(wrist: 15))
        let fast = FlightSimulator.simulate(swing: swing(wrist: 28))
        #expect(fast.carry > slow.carry + 10)
    }

    @Test func badTempoCurvesMore() {
        let good = FlightSimulator.simulate(swing: swing(back: 0.75, down: 0.25, path: -0.5))
        let rushed = FlightSimulator.simulate(swing: swing(back: 0.45, down: 0.25, path: -0.5))
        #expect(abs(rushed.offline) > abs(good.offline))
    }

    @Test func roughSwingLosesDistance() {
        let smooth = FlightSimulator.simulate(swing: swing(smooth: 1))
        let rough = FlightSimulator.simulate(swing: swing(smooth: 0))
        #expect(rough.carry < smooth.carry)
    }

    @Test func rollsOutAndStopsOnGround() {
        let r = FlightSimulator.simulate(swing: .sample)
        #expect(r.total >= r.carry)
        #expect(r.restPoint.y == 0)
        #expect(r.landingPoint.y == 0)
        #expect(r.duration < FlightTuning.standard.maxFlightTime)
        let roll = Units.yards(r.total - r.carry)
        #expect(roll > 2 && roll < 30, "roll \(roll) yd")
    }

    @Test func apexLooksLikeAnIron() {
        let r = FlightSimulator.simulate(swing: .sample)
        #expect(r.apex > 15 && r.apex < 40, "apex \(r.apex) m")
    }

    @Test func sameSwingSameShot() {
        let a = FlightSimulator.simulate(swing: swing(smooth: 0.3))
        let b = FlightSimulator.simulate(swing: swing(smooth: 0.3))
        #expect(a == b)
    }

    @Test func pointsAreInTimeOrder() {
        let r = FlightSimulator.simulate(swing: .sample)
        #expect(zip(r.points, r.points.dropFirst()).allSatisfy { $0.time < $1.time })
    }
}
