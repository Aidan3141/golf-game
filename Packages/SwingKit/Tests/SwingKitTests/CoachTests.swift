import Foundation
import Testing
@testable import SwingKit

private func swing(back: Double = 0.9, down: Double = 0.3, smooth: Double = 0.8, wrist: Double = 20,
                   path: Double = 0, hand: Handedness = .right) -> SwingResult {
    SwingResult(handedness: hand, backswingDuration: back, downswingDuration: down,
                peakWristAngularVelocity: wrist, peakAcceleration: 10, smoothnessScore: smooth,
                pathBias: path, confidence: 1)
}

private func tip(_ s: SwingResult) -> CoachingTip {
    Coach.tip(for: s, flight: FlightSimulator.simulate(swing: s))
}

@Suite struct CoachTests {
    @Test func rushed() {
        let t = tip(swing(back: 0.6, down: 0.33))
        #expect(t.kind == .rushedTempo)
        #expect(t.detail.contains("1.8"))
    }

    @Test func slow() {
        #expect(tip(swing(back: 1.2, down: 0.3)).kind == .slowTempo)
    }

    @Test func tempoBeatsEverythingElse() {
        // rushed + jerky + slicing -> fix tempo first
        #expect(tip(swing(back: 0.5, down: 0.3, smooth: 0.2, path: -1)).kind == .rushedTempo)
    }

    @Test func jerky() {
        #expect(tip(swing(smooth: 0.3)).kind == .jerky)
    }

    @Test(arguments: [Handedness.right, .left])
    func sliceAndHookByHand(hand: Handedness) {
        #expect(tip(swing(path: -1, hand: hand)).kind == .slice)
        #expect(tip(swing(path: 1, hand: hand)).kind == .hook)
    }

    @Test func pure() {
        #expect(tip(swing(back: 0.9, down: 0.3, smooth: 0.9)).kind == .great)
    }

    @Test func sessionStats() {
        let swings = [swing(back: 0.9, down: 0.3), swing(back: 0.6, down: 0.3), swing(back: 1.2, down: 0.3)]
        let flights = swings.map { FlightSimulator.simulate(swing: $0) }
        let s = SessionStats(swings: swings, flights: flights)
        #expect(s.shots == 3)
        #expect(abs(s.averageTempo - 3) < 1e-9)
        #expect(abs(s.tempoSpread - 1) < 1e-9)
        #expect(s.bestCarry == flights.map(\.carry).max())
        #expect(SessionStats(swings: [], flights: []).shots == 0)
    }
}
